#!/bin/bash
set -euo pipefail

# Disable AWS CLI pager (compatible with both v1 and v2)
export AWS_PAGER=""

# =============================================================================
# Super Agent — Full Deploy Script (CDK + CloudFront + AgentCore)
#
# Deploys the complete stack: CDK infra with CloudFront CDN (local auth),
# then sets up AgentCore Runtime (ECR, IAM, container build/push, Runtime).
#
# Prerequisites:
#   - AWS CLI v2 + SSM Session Manager plugin
#   - Docker (with buildx, ARM64 support — native on Apple Silicon)
#   - Node.js 22+
#   - An EC2 Key Pair in the target region
#
# Usage:
#   ./deploy-full.sh <SSH_KEY> [options]
#
# Options:
#   --stack <name>          CloudFormation stack name (default: SuperAgent)
#   --region <region>       AWS region (default: us-west-2)
#   --domain <domain>       Custom domain for CloudFront (requires --hosted-zone-id)
#   --hosted-zone-id <id>   Route53 hosted zone ID
#   --bedrock-ak <key>      Bedrock AWS Access Key (cross-account, optional)
#   --bedrock-sk <secret>   Bedrock AWS Secret Key (cross-account, optional)
#   --bedrock-api-key <key> Bedrock API Key / bearer token (preferred, overrides AK/SK)
#   --litellm-url <url>     LiteLLM proxy base URL (e.g. http://host:4000)
#   --litellm-key <key>     LiteLLM API key
#   --litellm-model <model> Model name on LiteLLM (e.g. claude-4.7)
#   --skip-cdk              Skip CDK deploy (reuse existing stack)
#   --skip-agentcore        Skip AgentCore setup
#   --skip-frontend         Skip frontend build/sync
#   --skip-backend          Skip backend build/sync
#
# Examples:
#   # Full deploy with custom domain:
#   ./deploy-full.sh ~/my-key.pem --domain app.example.com --hosted-zone-id Z0123
#
#   # Full deploy, IP-only (no custom domain):
#   ./deploy-full.sh ~/my-key.pem
#
#   # Redeploy code only (stack + AgentCore already exist):
#   ./deploy-full.sh ~/my-key.pem --skip-cdk
#
# =============================================================================

SSH_KEY="${1:?Usage: ./deploy-full.sh <SSH_KEY_PATH> [options]}"
shift

STACK_NAME="SuperAgent"
REGION="us-west-2"
DOMAIN_NAME=""
HOSTED_ZONE_ID=""
BEDROCK_AK=""
BEDROCK_SK=""
BEDROCK_API_KEY="${BEDROCK_API_KEY:-}"
LITELLM_URL="${LITELLM_BASE_URL:-}"
LITELLM_KEY="${LITELLM_API_KEY:-}"
LITELLM_MODEL=""
SKIP_CDK=false
SKIP_AGENTCORE=false
SKIP_FRONTEND=false
SKIP_BACKEND=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)            STACK_NAME="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --domain)           DOMAIN_NAME="$2"; shift 2 ;;
    --hosted-zone-id)   HOSTED_ZONE_ID="$2"; shift 2 ;;
    --bedrock-ak)       BEDROCK_AK="$2"; shift 2 ;;
    --bedrock-sk)       BEDROCK_SK="$2"; shift 2 ;;
    --bedrock-api-key)  BEDROCK_API_KEY="$2"; shift 2 ;;
    --litellm-url)      LITELLM_URL="$2"; shift 2 ;;
    --litellm-key)      LITELLM_KEY="$2"; shift 2 ;;
    --litellm-model)    LITELLM_MODEL="$2"; shift 2 ;;
    --skip-cdk)         SKIP_CDK=true; shift ;;
    --skip-agentcore)   SKIP_AGENTCORE=true; shift ;;
    --skip-frontend)    SKIP_FRONTEND=true; shift ;;
    --skip-backend)     SKIP_BACKEND=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/super-agent-agentcore"

echo "============================================="
echo "  Super Agent Full Deploy"
echo "  Account:  $ACCOUNT_ID"
echo "  Region:   $REGION"
echo "  Stack:    $STACK_NAME"
[ -n "$DOMAIN_NAME" ] && echo "  Domain:   $DOMAIN_NAME"
[ -n "$LITELLM_URL" ] && echo "  LiteLLM:  $LITELLM_URL (model: ${LITELLM_MODEL:-default})"
echo "============================================="

# =========================================================================
# Phase 1: CDK Deploy
# =========================================================================
if [ "$SKIP_CDK" = false ]; then
  echo ""
  echo "=== Phase 1: CDK Deploy ==="
  cd "$SCRIPT_DIR/.."

  npm install

  CDK_ARGS="-c stackName=$STACK_NAME -c enableCdn=true"
  CDK_PARAMS="--parameters KeyPairName=$(basename "$SSH_KEY" .pem) --parameters AllowedCidr=0.0.0.0/0"

  if [ -n "$DOMAIN_NAME" ] && [ -n "$HOSTED_ZONE_ID" ]; then
    CDK_ARGS="$CDK_ARGS -c domainName=$DOMAIN_NAME -c hostedZoneId=$HOSTED_ZONE_ID"
  fi

  echo "  Running: npx cdk deploy $CDK_ARGS $CDK_PARAMS --region $REGION --require-approval never"
  npx cdk deploy $CDK_ARGS $CDK_PARAMS --region "$REGION" --require-approval never

  echo "  Waiting for EC2 SSM agent..."
  INSTANCE_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

  for i in $(seq 1 30); do
    STATUS=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
      --region "$REGION" \
      --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || echo "None")
    [ "$STATUS" = "Online" ] && echo "  SSM agent online." && break
    echo "  Attempt $i/30 - status: $STATUS, waiting 10s..."
    sleep 10
  done

  # Wait for UserData bootstrap to complete (fetch-db-url.sh is created at the end)
  echo "  Waiting for EC2 UserData bootstrap to complete..."
  for i in $(seq 1 60); do
    BOOTSTRAP_CHECK=$(aws ssm send-command \
      --instance-ids "$INSTANCE_ID" --region "$REGION" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["test -f /opt/super-agent/fetch-db-url.sh && echo READY || echo WAITING"]' \
      --output text --query "Command.CommandId" 2>/dev/null || echo "")
    if [ -n "$BOOTSTRAP_CHECK" ]; then
      sleep 5
      RESULT=$(aws ssm get-command-invocation \
        --command-id "$BOOTSTRAP_CHECK" --instance-id "$INSTANCE_ID" \
        --region "$REGION" --query "StandardOutputContent" --output text 2>/dev/null || echo "WAITING")
      if echo "$RESULT" | grep -q "READY"; then
        echo "  EC2 bootstrap complete."
        break
      fi
    fi
    echo "  Attempt $i/60 - bootstrap still running, waiting 10s..."
    sleep 10
  done
else
  echo ""
  echo "=== Phase 1: CDK Deploy (skipped) ==="
fi

# =========================================================================
# Fix CloudFront EC2 origin (replace placeholder with actual EC2 public DNS)
# =========================================================================
if [ -n "$DOMAIN_NAME" ]; then
  CF_DIST_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" --output text 2>/dev/null || echo "")
  if [ -n "$CF_DIST_ID" ] && [ "$CF_DIST_ID" != "None" ]; then
    INSTANCE_ID_FOR_DNS=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
    EC2_PUBLIC_DNS=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID_FOR_DNS" --region "$REGION" \
      --query "Reservations[0].Instances[0].PublicDnsName" --output text 2>/dev/null || echo "")
    if [ -n "$EC2_PUBLIC_DNS" ] && [ "$EC2_PUBLIC_DNS" != "None" ]; then
      # Check if origin still has placeholder
      CURRENT_ORIGINS=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" \
        --query "DistributionConfig.Origins.Items[*].DomainName" --output text 2>/dev/null || echo "")
      if echo "$CURRENT_ORIGINS" | grep -q "ec2-placeholder"; then
        echo ""
        echo "=== Updating CloudFront EC2 origin → $EC2_PUBLIC_DNS ==="
        CF_ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "ETag" --output text)
        aws cloudfront get-distribution-config --id "$CF_DIST_ID" --output json | \
          python3 -c "
import sys, json
data = json.load(sys.stdin)
config = data['DistributionConfig']
for origin in config['Origins']['Items']:
    if 'ec2-placeholder' in origin['DomainName']:
        origin['DomainName'] = '$EC2_PUBLIC_DNS'
json.dump(config, open('/tmp/cf-origin-fix.json', 'w'))
"
        aws cloudfront update-distribution --id "$CF_DIST_ID" --if-match "$CF_ETAG" \
          --distribution-config file:///tmp/cf-origin-fix.json \
          --query "Distribution.Status" --output text 2>/dev/null || true
        rm -f /tmp/cf-origin-fix.json
        echo "  CloudFront origin updated."
      fi
    fi
  fi
fi

# =========================================================================
# Phase 2: Run existing deploy.sh for .env + frontend + backend
# =========================================================================
echo ""
echo "=== Phase 2: Code Deploy (deploy.sh) ==="

DEPLOY_ARGS="$SSH_KEY --stack $STACK_NAME --region $REGION"
[ "$SKIP_FRONTEND" = true ] && DEPLOY_ARGS="$DEPLOY_ARGS --skip-frontend"
[ "$SKIP_BACKEND" = true ] && DEPLOY_ARGS="$DEPLOY_ARGS --skip-backend"
# Propagate Bedrock credentials so deploy.sh writes them into the backend .env.
# Without these, BEDROCK_API_KEY would only reach the AgentCore container (Phase 3)
# and never make it to the backend process on EC2.
[ -n "$BEDROCK_API_KEY" ] && DEPLOY_ARGS="$DEPLOY_ARGS --bedrock-api-key $BEDROCK_API_KEY"
# Propagate LiteLLM config to deploy.sh
[ -n "$LITELLM_URL" ] && DEPLOY_ARGS="$DEPLOY_ARGS --litellm-url $LITELLM_URL"
[ -n "$LITELLM_KEY" ] && DEPLOY_ARGS="$DEPLOY_ARGS --litellm-key $LITELLM_KEY"
[ -n "$LITELLM_MODEL" ] && DEPLOY_ARGS="$DEPLOY_ARGS --litellm-model $LITELLM_MODEL"

"$SCRIPT_DIR/deploy.sh" $DEPLOY_ARGS

# =========================================================================
# Phase 3: AgentCore Setup
# =========================================================================
if [ "$SKIP_AGENTCORE" = false ]; then
  echo ""
  echo "=== Phase 3: AgentCore Setup ==="

  # --- 3a: ECR Repository ---
  echo "  [3a] Ensuring ECR repository..."
  aws ecr describe-repositories --repository-names super-agent-agentcore --region "$REGION" 2>/dev/null \
    || aws ecr create-repository --repository-name super-agent-agentcore --region "$REGION"
  echo "  ECR: $ECR_URI"

  # --- 3b: IAM Execution Role ---
  # Role and policy names are scoped by stack name to avoid conflicts
  # when multiple stacks share the same AWS account.
  echo "  [3b] Ensuring IAM execution role..."
  ROLE_NAME="super-agent-agentcore-role-${STACK_NAME}"
  POLICY_NAME="agentcore-permissions-${STACK_NAME}"

  if ! aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
    echo "  Creating role $ROLE_NAME..."
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }]
      }' \
      --description "Execution role for Super Agent AgentCore containers ($STACK_NAME)"
  fi

  # Always update permissions to latest
  echo "  Updating permissions policy ($POLICY_NAME)..."
  # Read the actual workspace bucket name from stack outputs (matches CDK: super-agent-workspace-<account>)
  WORKSPACE_BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='WorkspaceBucketName'].OutputValue" --output text 2>/dev/null || echo "super-agent-workspace-$ACCOUNT_ID")
  SKILLS_BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='SkillsBucketName'].OutputValue" --output text 2>/dev/null || echo "")
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Sid\": \"BedrockInvoke\",
          \"Effect\": \"Allow\",
          \"Action\": [\"bedrock:InvokeModel\", \"bedrock:InvokeModelWithResponseStream\"],
          \"Resource\": \"*\"
        },
        {
          \"Sid\": \"WorkspaceS3\",
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:ListBucket\", \"s3:DeleteObject\"],
          \"Resource\": [
            \"arn:aws:s3:::$WORKSPACE_BUCKET_NAME\",
            \"arn:aws:s3:::$WORKSPACE_BUCKET_NAME/*\"
          ]
        },
        {
          \"Sid\": \"SkillsS3\",
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
          \"Resource\": [
            \"arn:aws:s3:::$SKILLS_BUCKET_NAME\",
            \"arn:aws:s3:::$SKILLS_BUCKET_NAME/*\"
          ]
        },
        {
          \"Sid\": \"ECRPull\",
          \"Effect\": \"Allow\",
          \"Action\": [\"ecr:GetDownloadUrlForLayer\", \"ecr:BatchGetImage\", \"ecr:GetAuthorizationToken\"],
          \"Resource\": \"*\"
        },
        {
          \"Sid\": \"BrowserTool\",
          \"Effect\": \"Allow\",
          \"Action\": [
            \"bedrock-agentcore:CreateBrowser\",
            \"bedrock-agentcore:ListBrowsers\",
            \"bedrock-agentcore:GetBrowser\",
            \"bedrock-agentcore:DeleteBrowser\",
            \"bedrock-agentcore:StartBrowserSession\",
            \"bedrock-agentcore:StopBrowserSession\",
            \"bedrock-agentcore:GetBrowserSession\",
            \"bedrock-agentcore:ListBrowserSessions\",
            \"bedrock-agentcore:ConnectBrowserAutomationStream\",
            \"bedrock-agentcore:ConnectBrowserLiveViewStream\",
            \"bedrock-agentcore:UpdateBrowserStream\"
          ],
          \"Resource\": \"arn:aws:bedrock-agentcore:*:*:browser/*\"
        },
        {
          \"Sid\": \"CodeInterpreter\",
          \"Effect\": \"Allow\",
          \"Action\": [
            \"bedrock-agentcore:StartCodeInterpreterSession\",
            \"bedrock-agentcore:InvokeCodeInterpreter\",
            \"bedrock-agentcore:StopCodeInterpreterSession\",
            \"bedrock-agentcore:GetCodeInterpreterSession\",
            \"bedrock-agentcore:ListCodeInterpreterSessions\"
          ],
          \"Resource\": \"arn:aws:bedrock-agentcore:*:*:code-interpreter/*\"
        }
      ]
    }"

  # --- 3c: Build + Push Docker Image ---
  echo "  [3c] Building and pushing AgentCore container..."
  aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

  cd "$PROJECT_ROOT/agentcore"
  docker buildx build --platform linux/arm64 \
    -t "super-agent-agentcore:latest" \
    -t "$ECR_URI:latest" \
    --load .
  docker push "$ECR_URI:latest"
  echo "  Image pushed: $ECR_URI:latest"

  # --- 3d: Create or Update AgentCore Runtime ---
  echo "  [3d] Creating/updating AgentCore Runtime..."
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/$ROLE_NAME"

  # VPC mode with private subnets + NAT Gateway for internet access.
  # AgentCore containers in VPC mode don't get public IPs, so they need
  # a NAT Gateway to reach the internet (for LiteLLM, pip packages, etc.).
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region "$REGION" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "")

  if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    echo "  VPC: $VPC_ID"

    # Get a public subnet for the NAT Gateway
    PUBLIC_SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
      --region "$REGION" --query "Subnets[0].SubnetId" --output text 2>/dev/null)
    PUBLIC_SUBNET_AZ=$(aws ec2 describe-subnets --subnet-ids "$PUBLIC_SUBNET" --region "$REGION" \
      --query "Subnets[0].AvailabilityZone" --output text 2>/dev/null)

    # Create or find private subnet for AgentCore (shared across stacks in same VPC)
    PRIVATE_SUBNET_NAME="super-agent-agentcore-private"
    PRIVATE_CIDR="172.31.128.0/20"
    PRIVATE_SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$PRIVATE_CIDR" \
      --region "$REGION" --query "Subnets[0].SubnetId" --output text 2>/dev/null || echo "")

    if [ -z "$PRIVATE_SUBNET_ID" ] || [ "$PRIVATE_SUBNET_ID" = "None" ]; then
      echo "  Creating private subnet + NAT Gateway..."
      PRIVATE_SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_CIDR" \
        --availability-zone "$PUBLIC_SUBNET_AZ" --region "$REGION" \
        --query "Subnet.SubnetId" --output text)
      aws ec2 create-tags --resources "$PRIVATE_SUBNET_ID" --tags "Key=Name,Value=$PRIVATE_SUBNET_NAME" --region "$REGION"
      echo "  Private subnet: $PRIVATE_SUBNET_ID ($PRIVATE_CIDR in $PUBLIC_SUBNET_AZ)"
    else
      echo "  Private subnet exists: $PRIVATE_SUBNET_ID"
    fi

    # Ensure NAT Gateway exists for the private subnet
    NAT_GW_ID=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=available" "Name=vpc-id,Values=$VPC_ID" \
      --region "$REGION" --query "NatGateways[0].NatGatewayId" --output text 2>/dev/null || echo "")
    if [ -z "$NAT_GW_ID" ] || [ "$NAT_GW_ID" = "None" ]; then
      echo "  No active NAT Gateway found, creating one..."
      EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=super-agent-nat-eip}]" \
        --query "AllocationId" --output text)
      NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET" --allocation-id "$EIP_ALLOC" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=super-agent-nat}]" \
        --region "$REGION" --query "NatGateway.NatGatewayId" --output text)
      echo "  NAT Gateway: $NAT_GW_ID (waiting for available...)"
      for i in $(seq 1 30); do
        NAT_STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" --region "$REGION" \
          --query "NatGateways[0].State" --output text 2>/dev/null || echo "pending")
        [ "$NAT_STATE" = "available" ] && echo "  NAT Gateway available." && break
        echo "  Attempt $i/30 - NAT state: $NAT_STATE, waiting 10s..."
        sleep 10
      done
    else
      echo "  NAT Gateway exists: $NAT_GW_ID"
    fi

    # Ensure route table exists for private subnet with NAT route
    RT_ID=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_ID" \
      --region "$REGION" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || echo "")
    if [ -z "$RT_ID" ] || [ "$RT_ID" = "None" ]; then
      RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=super-agent-private-rt}]" \
        --query "RouteTable.RouteTableId" --output text)
      aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "$NAT_GW_ID" --region "$REGION" > /dev/null
      aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$PRIVATE_SUBNET_ID" \
        --region "$REGION" > /dev/null
      echo "  Route table: $RT_ID (0.0.0.0/0 → NAT)"
    fi

    # Create or find AgentCore security group (shared across stacks)
    AGENTCORE_SG_NAME="super-agent-agentcore-sg"
    AGENTCORE_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$AGENTCORE_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
      --region "$REGION" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")
    if [ -z "$AGENTCORE_SG_ID" ] || [ "$AGENTCORE_SG_ID" = "None" ]; then
      echo "  Creating AgentCore security group..."
      AGENTCORE_SG_ID=$(aws ec2 create-security-group --group-name "$AGENTCORE_SG_NAME" \
        --description "AgentCore Runtime containers - all outbound" \
        --vpc-id "$VPC_ID" --region "$REGION" --query "GroupId" --output text)
    fi
    echo "  SG: $AGENTCORE_SG_ID"

    NETWORK_CONFIG="{\"networkMode\":\"VPC\",\"networkModeConfig\":{\"securityGroups\":[\"${AGENTCORE_SG_ID}\"],\"subnets\":[\"${PRIVATE_SUBNET_ID}\"]}}"
  else
    echo "  WARNING: Default VPC not found, falling back to PUBLIC network mode"
    NETWORK_CONFIG='{"networkMode":"PUBLIC"}'
  fi

  # Build environment variables JSON.
  # If LiteLLM proxy is configured (--litellm-url), route through it.
  # Otherwise fall back to Bedrock API Key or AK/SK.
  if [ -n "$LITELLM_URL" ]; then
    EFFECTIVE_MODEL="${LITELLM_MODEL:-claude-sonnet-4-5-20250929}"
    ENV_VARS="{\"CLAUDE_CODE_USE_BEDROCK\":\"0\",\"ANTHROPIC_API_KEY\":\"${LITELLM_KEY}\",\"ANTHROPIC_BASE_URL\":\"${LITELLM_URL}\",\"ANTHROPIC_MODEL\":\"${EFFECTIVE_MODEL}\",\"CLAUDE_MODEL\":\"${EFFECTIVE_MODEL}\",\"AWS_REGION\":\"$REGION\",\"AWS_DEFAULT_REGION\":\"$REGION\",\"WORKSPACE_S3_REGION\":\"$REGION\""
  else
    ENV_VARS="{\"CLAUDE_CODE_USE_BEDROCK\":\"1\",\"ANTHROPIC_MODEL\":\"us.anthropic.claude-sonnet-4-5-20250929-v1:0\",\"AWS_REGION\":\"$REGION\",\"AWS_DEFAULT_REGION\":\"$REGION\",\"WORKSPACE_S3_REGION\":\"$REGION\""
  fi
  if [ -n "$BEDROCK_API_KEY" ]; then
    ENV_VARS="$ENV_VARS,\"AWS_BEARER_TOKEN_BEDROCK\":\"$BEDROCK_API_KEY\",\"BEDROCK_API_KEY\":\"$BEDROCK_API_KEY\",\"AWS_AUTH_SCHEME_PREFERENCE\":\"httpBearerAuth\""
  elif [ -n "$BEDROCK_AK" ] && [ -n "$BEDROCK_SK" ]; then
    ENV_VARS="$ENV_VARS,\"AWS_ACCESS_KEY_ID\":\"$BEDROCK_AK\",\"AWS_SECRET_ACCESS_KEY\":\"$BEDROCK_SK\""
  fi
  ENV_VARS="$ENV_VARS}"

  # Try to find existing runtime (stack-scoped name)
  RUNTIME_NAME="${STACK_NAME}Runtime"
  RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
    --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId" \
    --output text 2>/dev/null || echo "")

  if [ -n "$RUNTIME_ID" ] && [ "$RUNTIME_ID" != "None" ]; then
    echo "  Updating existing runtime: $RUNTIME_ID"
    aws bedrock-agentcore-control update-agent-runtime \
      --agent-runtime-id "$RUNTIME_ID" \
      --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"$ECR_URI:latest\"}}" \
      --role-arn "$ROLE_ARN" \
      --network-configuration "$NETWORK_CONFIG" \
      --environment-variables "$ENV_VARS" \
      --region "$REGION"
  else
    echo "  Creating new runtime..."
    RUNTIME_OUTPUT=$(aws bedrock-agentcore-control create-agent-runtime \
      --agent-runtime-name "${RUNTIME_NAME}" \
      --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"$ECR_URI:latest\"}}" \
      --role-arn "$ROLE_ARN" \
      --network-configuration "$NETWORK_CONFIG" \
      --environment-variables "$ENV_VARS" \
      --description "Super Agent AgentCore Runtime" \
      --region "$REGION" --output json)
    RUNTIME_ID=$(echo "$RUNTIME_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['agentRuntimeId'])")
  fi

  RUNTIME_ARN="arn:aws:bedrock-agentcore:$REGION:$ACCOUNT_ID:runtime/$RUNTIME_ID"
  echo "  Runtime ARN: $RUNTIME_ARN"

  # Wait for runtime to be READY
  echo "  Waiting for runtime to be READY..."
  for i in $(seq 1 30); do
    RT_STATUS=$(aws bedrock-agentcore-control get-agent-runtime \
      --agent-runtime-id "$RUNTIME_ID" --region "$REGION" \
      --query 'status' --output text 2>/dev/null || echo "UNKNOWN")
    [ "$RT_STATUS" = "READY" ] && echo "  Runtime is READY." && break
    echo "  Attempt $i/30 - status: $RT_STATUS, waiting 10s..."
    sleep 10
  done

  if [ "$RT_STATUS" != "READY" ]; then
    echo "WARNING: Runtime not READY after 5 minutes (status: $RT_STATUS). Continuing anyway."
  fi

  # --- 3e: Update EC2 .env to enable AgentCore ---
  echo "  [3e] Enabling AgentCore mode on EC2..."
  INSTANCE_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

  # Determine values for .env update
  if [ -n "$LITELLM_URL" ]; then
    BEDROCK_FLAG="0"
    EFFECTIVE_MODEL="${LITELLM_MODEL:-claude-sonnet-4-5-20250929}"
  else
    BEDROCK_FLAG="1"
    EFFECTIVE_MODEL="claude-sonnet-4-5-20250929"
  fi

  aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[
      \"sed -i 's/^AGENT_RUNTIME=.*/AGENT_RUNTIME=agentcore/' /opt/super-agent/.env\",
      \"sed -i 's/^CLAUDE_CODE_USE_BEDROCK=.*/CLAUDE_CODE_USE_BEDROCK=$BEDROCK_FLAG/' /opt/super-agent/.env\",
      \"sed -i 's/^CLAUDE_MODEL=.*/CLAUDE_MODEL=$EFFECTIVE_MODEL/' /opt/super-agent/.env\",
      \"grep -q '^LITELLM_BASE_URL=' /opt/super-agent/.env && sed -i 's|^LITELLM_BASE_URL=.*|LITELLM_BASE_URL=$LITELLM_URL|' /opt/super-agent/.env || { [ -n '$LITELLM_URL' ] && echo 'LITELLM_BASE_URL=$LITELLM_URL' >> /opt/super-agent/.env || true; }\",
      \"grep -q '^LITELLM_API_KEY=' /opt/super-agent/.env && sed -i 's|^LITELLM_API_KEY=.*|LITELLM_API_KEY=$LITELLM_KEY|' /opt/super-agent/.env || { [ -n '$LITELLM_KEY' ] && echo 'LITELLM_API_KEY=$LITELLM_KEY' >> /opt/super-agent/.env || true; }\",
      \"grep -q '^AGENTCORE_RUNTIME_ARN=' /opt/super-agent/.env && sed -i 's|^AGENTCORE_RUNTIME_ARN=.*|AGENTCORE_RUNTIME_ARN=$RUNTIME_ARN|' /opt/super-agent/.env || echo 'AGENTCORE_RUNTIME_ARN=$RUNTIME_ARN' >> /opt/super-agent/.env\",
      \"grep -q '^AGENTCORE_EXECUTION_ROLE_ARN=' /opt/super-agent/.env && sed -i 's|^AGENTCORE_EXECUTION_ROLE_ARN=.*|AGENTCORE_EXECUTION_ROLE_ARN=$ROLE_ARN|' /opt/super-agent/.env || echo 'AGENTCORE_EXECUTION_ROLE_ARN=$ROLE_ARN' >> /opt/super-agent/.env\",
      \"grep -q '^AGENTCORE_WORKSPACE_S3_BUCKET=' /opt/super-agent/.env && sed -i 's|^AGENTCORE_WORKSPACE_S3_BUCKET=.*|AGENTCORE_WORKSPACE_S3_BUCKET=$WORKSPACE_BUCKET_NAME|' /opt/super-agent/.env || echo 'AGENTCORE_WORKSPACE_S3_BUCKET=$WORKSPACE_BUCKET_NAME' >> /opt/super-agent/.env\",
      \"systemctl restart backend\",
      \"sleep 2\",
      \"systemctl status backend --no-pager -l\"
    ]" \
    --output json --query "Command.CommandId" 2>/dev/null

  echo "  AgentCore mode enabled. Backend restarting..."
  sleep 5

else
  echo ""
  echo "=== Phase 3: AgentCore Setup (skipped) ==="
fi

# =========================================================================
# Done
# =========================================================================
echo ""
echo "============================================="
echo "  Full Deployment Complete!"
echo "============================================="
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text 2>/dev/null || echo "")
PUBLIC_IP=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='PublicIP'].OutputValue" --output text 2>/dev/null || echo "")
if [ -n "$DOMAIN_NAME" ]; then
  echo "  App URL:    https://$DOMAIN_NAME"
else
  echo "  App URL:    https://$PUBLIC_IP"
fi
echo "  Instance:   $INSTANCE_ID"
[ "$SKIP_AGENTCORE" = false ] && echo "  AgentCore:  $RUNTIME_ARN"
echo "  SSM:        aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo "============================================="
