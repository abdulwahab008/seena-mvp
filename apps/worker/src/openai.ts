import OpenAI from 'openai';
import { env } from './env.js';

let _client: OpenAI | null = null;

/** OpenAI-compatible client pointed at OpenRouter. Used for embeddings (passthrough to OpenAI). */
export function llm(): OpenAI {
  if (_client) return _client;
  const e = env();
  _client = new OpenAI({
    apiKey: e.OPENROUTER_API_KEY,
    baseURL: e.OPENROUTER_BASE_URL,
    timeout: 300_000,
    maxRetries: 2,
    defaultHeaders: {
      'HTTP-Referer': e.OPENROUTER_APP_URL,
      'X-Title': e.OPENROUTER_APP_NAME,
    },
  });
  return _client;
}

const BATCH_SIZE = 100;

export type EmbedResult = { vectors: number[][]; totalTokens: number };

export async function embedTexts(texts: string[], model?: string): Promise<EmbedResult> {
  if (texts.length === 0) return { vectors: [], totalTokens: 0 };
  const useModel = model ?? env().OPENROUTER_EMBEDDING_MODEL;
  const vectors: number[][] = [];
  let totalTokens = 0;
  for (let i = 0; i < texts.length; i += BATCH_SIZE) {
    const batch = texts.slice(i, i + BATCH_SIZE);
    const res = await llm().embeddings.create({
      model: useModel,
      input: batch,
      encoding_format: 'float',
    });
    for (const item of res.data) vectors.push(item.embedding);
    totalTokens += res.usage?.total_tokens ?? 0;
  }
  return { vectors, totalTokens };
}

// USD per 1M tokens. OpenRouter passes through provider rates; these are
// conservative defaults for quota accounting — real cost is reconciled from
// the OpenRouter dashboard, same tolerance as apps/web/lib/llm.ts's PRICING.
const EMBED_PRICING: Record<string, number> = {
  'openai/text-embedding-3-large': 0.13,
};
const CHAT_PRICING: Record<string, { input: number; output: number }> = {
  'google/gemini-3.5-flash': { input: 0.1, output: 0.4 },
};

export function estimateEmbedCostUsd(model: string, tokens: number): number {
  const perMillion = EMBED_PRICING[model] ?? 0.13;
  return (tokens * perMillion) / 1_000_000;
}

export function estimateChatCostUsd(model: string, inputTokens: number, outputTokens: number): number {
  const p = CHAT_PRICING[model] ?? { input: 0.5, output: 1.5 };
  return (inputTokens * p.input + outputTokens * p.output) / 1_000_000;
}
