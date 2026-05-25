/**
 * LLM Proxy Service
 *
 * Core service that handles OpenAI-compatible chat completions by proxying
 * requests to a LiteLLM proxy instance (Tokyo region). Falls back to direct
 * Bedrock if LITELLM_BASE_URL is not configured.
 *
 * Integrates with the platform's API key auth and token usage tracking.
 */

import {
  BedrockRuntimeClient,
  ConverseCommand,
  ConverseStreamCommand,
} from '@aws-sdk/client-bedrock-runtime';
import { randomUUID } from 'crypto';
import { config } from '../../config/index.js';
import { createBedrockClient } from '../bedrock-client.js';
import { OpenAIToBedrockConverter } from './openai-to-bedrock.js';
import { BedrockToOpenAIConverter } from './bedrock-to-openai.js';
import { recordTokenUsage } from '../token-usage.service.js';
import type {
  ChatCompletionRequest,
  ChatCompletionResponse,
} from './types.js';
import { DEFAULT_MODEL_MAPPING as MODEL_MAP, MODEL_CATALOG } from './types.js';

// ============================================================================
// LiteLLM Proxy helpers
// ============================================================================

function getLiteLLMBaseUrl(): string | undefined {
  return config.litellm.baseUrl;
}

function getLiteLLMHeaders(): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (config.litellm.apiKey) {
    headers['Authorization'] = `Bearer ${config.litellm.apiKey}`;
  }
  return headers;
}

// ============================================================================
// Bedrock Client (singleton) — fallback when LiteLLM is not configured
// ============================================================================

let bedrockClient: BedrockRuntimeClient | null = null;

function getBedrockClient(): BedrockRuntimeClient {
  if (bedrockClient) return bedrockClient;
  bedrockClient = createBedrockClient({ region: config.aws.region, maxAttempts: 3 });
  return bedrockClient;
}

// ============================================================================
// Service
// ============================================================================

export interface LLMProxyResult {
  response: ChatCompletionResponse;
  cacheUsage: Record<string, number>;
}

export class LLMProxyService {
  private converter = new OpenAIToBedrockConverter();
  private responseConverter = new BedrockToOpenAIConverter();

  private get useLiteLLM(): boolean {
    return !!getLiteLLMBaseUrl();
  }

  /**
   * Non-streaming chat completion.
   */
  async chatCompletion(
    request: ChatCompletionRequest,
    requestId?: string,
    cacheTtl?: string | null,
  ): Promise<LLMProxyResult> {
    if (this.useLiteLLM) {
      return this.litellmChatCompletion(request, requestId);
    }
    return this.bedrockChatCompletion(request, requestId, cacheTtl);
  }

  /**
   * Streaming chat completion — yields SSE strings.
   */
  async *chatCompletionStream(
    request: ChatCompletionRequest,
    requestId?: string,
    cacheTtl?: string | null,
  ): AsyncGenerator<string> {
    if (this.useLiteLLM) {
      yield* this.litellmChatCompletionStream(request, requestId);
    } else {
      yield* this.bedrockChatCompletionStream(request, requestId, cacheTtl);
    }
  }

  /**
   * List available models with capability info.
   */
  listModels(): Record<string, unknown>[] {
    return MODEL_CATALOG.map((m) => ({
      id: m.id,
      object: 'model',
      created: 1700000000,
      owned_by: m.provider,
      display_name: m.displayName,
      capabilities: m.capabilities,
      protocols: m.protocols,
    }));
  }

  // ==========================================================================
  // LiteLLM implementation
  // ==========================================================================

  private async litellmChatCompletion(
    request: ChatCompletionRequest,
    requestId?: string,
  ): Promise<LLMProxyResult> {
    const id = requestId ?? `chatcmpl-${randomUUID().replace(/-/g, '').slice(0, 24)}`;
    const baseUrl = getLiteLLMBaseUrl()!;
    // If URL already contains /v1/chat/completions, use as-is.
    // Otherwise strip known path suffixes and append /v1/chat/completions.
    let url: string;
    if (baseUrl.includes('/v1/chat/completions')) {
      url = baseUrl;
    } else {
      const stripped = baseUrl.replace(/\/+$/, '').replace(/\/v1\/messages$/, '').replace(/\/v1$/, '');
      url = `${stripped}/v1/chat/completions`;
    }

    const body = {
      ...request,
      stream: false,
    };

    const resp = await fetch(url, {
      method: 'POST',
      headers: getLiteLLMHeaders(),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(120_000),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`LiteLLM proxy error ${resp.status}: ${errText}`);
    }

    const data = (await resp.json()) as ChatCompletionResponse;
    // Normalize the response ID
    data.id = id;

    const cacheUsage: Record<string, number> = {};
    if (data.usage) {
      if ((data.usage as any).prompt_tokens_details?.cached_tokens) {
        cacheUsage.cacheReadInputTokens = (data.usage as any).prompt_tokens_details.cached_tokens;
      }
    }

    return { response: data, cacheUsage };
  }

  private async *litellmChatCompletionStream(
    request: ChatCompletionRequest,
    requestId?: string,
  ): AsyncGenerator<string> {
    const id = requestId ?? `chatcmpl-${randomUUID().replace(/-/g, '').slice(0, 24)}`;
    const baseUrl = getLiteLLMBaseUrl()!;
    // If URL already contains /v1/chat/completions, use as-is.
    // Otherwise strip known path suffixes and append /v1/chat/completions.
    let url: string;
    if (baseUrl.includes('/v1/chat/completions')) {
      url = baseUrl;
    } else {
      const stripped = baseUrl.replace(/\/+$/, '').replace(/\/v1\/messages$/, '').replace(/\/v1$/, '');
      url = `${stripped}/v1/chat/completions`;
    }

    const body = {
      ...request,
      stream: true,
      stream_options: { include_usage: true, ...(request.stream_options ?? {}) },
    };

    const resp = await fetch(url, {
      method: 'POST',
      headers: getLiteLLMHeaders(),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(300_000),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`LiteLLM proxy error ${resp.status}: ${errText}`);
    }

    const reader = resp.body?.getReader();
    if (!reader) {
      yield 'data: [DONE]\n\n';
      return;
    }

    const decoder = new TextDecoder();
    let buffer = '';
    let usageData: Record<string, number> | null = null;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;

        if (trimmed === 'data: [DONE]') {
          // Will emit [DONE] at the end
          continue;
        }

        if (trimmed.startsWith('data: ')) {
          // Try to extract usage from the chunk
          try {
            const chunk = JSON.parse(trimmed.slice(6));
            if (chunk.usage) {
              usageData = {
                inputTokens: chunk.usage.prompt_tokens ?? 0,
                outputTokens: chunk.usage.completion_tokens ?? 0,
              };
              if (chunk.usage.prompt_tokens_details?.cached_tokens) {
                usageData.cacheReadInputTokens = chunk.usage.prompt_tokens_details.cached_tokens;
              }
            }
            // Replace the ID with our own
            if (chunk.id) chunk.id = id;
            yield `data: ${JSON.stringify(chunk)}\n\n`;
          } catch {
            // Pass through as-is if not valid JSON
            yield `${trimmed}\n\n`;
          }
        }
      }
    }

    yield 'data: [DONE]\n\n';

    // Emit internal usage marker for tracking
    if (usageData) {
      yield `__usage__:${JSON.stringify(usageData)}`;
    }
  }

  // ==========================================================================
  // Bedrock implementation (fallback)
  // ==========================================================================

  private async bedrockChatCompletion(
    request: ChatCompletionRequest,
    requestId?: string,
    cacheTtl?: string | null,
  ): Promise<LLMProxyResult> {
    const id = requestId ?? `chatcmpl-${randomUUID().replace(/-/g, '').slice(0, 24)}`;
    const client = getBedrockClient();

    const bedrockRequest = this.converter.convertRequest(request, cacheTtl);
    const modelId = bedrockRequest.modelId as string;
    delete bedrockRequest.modelId;

    const command = new ConverseCommand({ modelId, ...bedrockRequest } as any);
    const bedrockResponse = await client.send(command);

    const cacheUsage = this.responseConverter.extractCacheUsage(bedrockResponse as any);
    const response = this.responseConverter.convertResponse(
      bedrockResponse as any,
      request.model,
      id,
      cacheTtl,
    );

    return { response, cacheUsage };
  }

  private async *bedrockChatCompletionStream(
    request: ChatCompletionRequest,
    requestId?: string,
    cacheTtl?: string | null,
  ): AsyncGenerator<string> {
    const id = requestId ?? `chatcmpl-${randomUUID().replace(/-/g, '').slice(0, 24)}`;
    const client = getBedrockClient();
    const includeUsage = request.stream_options?.include_usage;

    const bedrockRequest = this.converter.convertRequest(request, cacheTtl);
    const modelId = bedrockRequest.modelId as string;
    delete bedrockRequest.modelId;

    const command = new ConverseStreamCommand({ modelId, ...bedrockRequest } as any);
    const bedrockResponse = await client.send(command);

    let currentIndex = 0;
    let usageData: Record<string, number> | null = null;
    const converter = new BedrockToOpenAIConverter();

    const stream = bedrockResponse.stream;
    if (!stream) {
      yield 'data: [DONE]\n\n';
      return;
    }

    for await (const event of stream) {
      const extracted = converter.extractStreamUsage(event as any);
      if (extracted) usageData = extracted;

      const sseEvents = converter.convertStreamEvent(event as any, request.model, id, currentIndex);
      for (const sse of sseEvents) {
        yield sse;
      }

      if ('contentBlockStart' in event) currentIndex++;
    }

    if (includeUsage && usageData) {
      yield converter.buildUsageChunk(id, request.model, usageData, cacheTtl);
    }

    yield 'data: [DONE]\n\n';

    if (usageData) {
      yield `__usage__:${JSON.stringify(usageData)}`;
    }
  }
}

// ============================================================================
// Token Usage Recording Helper
// ============================================================================

export async function recordLLMProxyUsage(params: {
  organizationId: string;
  userId: string;
  model: string;
  promptTokens: number;
  completionTokens: number;
  cachedTokens?: number;
  cacheWriteTokens?: number;
}): Promise<void> {
  try {
    await recordTokenUsage({
      organizationId: params.organizationId,
      userId: params.userId,
      source: 'chat' as const,
      model: params.model,
      tokenUsage: {
        inputTokens: params.promptTokens,
        outputTokens: params.completionTokens,
        cacheReadInputTokens: params.cachedTokens ?? 0,
        cacheCreationInputTokens: params.cacheWriteTokens ?? 0,
        totalCostUsd: 0, // TODO: add pricing calculation
      },
    });
  } catch (err) {
    console.error('[llm-proxy] Failed to record usage:', err);
  }
}
