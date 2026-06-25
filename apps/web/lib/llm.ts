import OpenAI from 'openai';
import { env } from './env';

declare global {
  // eslint-disable-next-line no-var
  var __llm: OpenAI | undefined;
}

/**
 * Single OpenAI-compatible client pointed at OpenRouter.
 * Used for both chat completions (any model) and embeddings (OpenAI passthrough).
 */
export function llm(): OpenAI {
  if (globalThis.__llm) return globalThis.__llm;
  const e = env();
  globalThis.__llm = new OpenAI({
    apiKey: e.OPENROUTER_API_KEY,
    baseURL: e.OPENROUTER_BASE_URL,
    timeout: 120_000,
    maxRetries: 2,
    defaultHeaders: {
      'HTTP-Referer': e.OPENROUTER_APP_URL,
      'X-Title': e.OPENROUTER_APP_NAME,
    },
  });
  return globalThis.__llm;
}

// Pricing (USD per 1M tokens). OpenRouter passes through provider rates;
// these are conservative defaults — the real cost is reported per generation
// by OpenRouter and can be reconciled later.
const PRICING: Record<string, { input: number; output: number }> = {
  'anthropic/claude-sonnet-4.5': { input: 3.0, output: 15.0 },
  'anthropic/claude-opus-4': { input: 15.0, output: 75.0 },
  'anthropic/claude-haiku-4.5': { input: 0.8, output: 4.0 },
  'openai/gpt-4o': { input: 2.5, output: 10.0 },
  'openai/gpt-4o-mini': { input: 0.15, output: 0.6 },
};

export function estimateCostUsd(model: string, inputTokens: number, outputTokens: number): number {
  const p = PRICING[model] ?? PRICING['anthropic/claude-sonnet-4.5']!;
  return (inputTokens * p.input + outputTokens * p.output) / 1_000_000;
}
