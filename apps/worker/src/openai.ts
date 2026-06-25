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

export async function embedTexts(texts: string[], model?: string): Promise<number[][]> {
  if (texts.length === 0) return [];
  const useModel = model ?? env().OPENROUTER_EMBEDDING_MODEL;
  const out: number[][] = [];
  for (let i = 0; i < texts.length; i += BATCH_SIZE) {
    const batch = texts.slice(i, i + BATCH_SIZE);
    const res = await llm().embeddings.create({
      model: useModel,
      input: batch,
      encoding_format: 'float',
    });
    for (const item of res.data) out.push(item.embedding);
  }
  return out;
}
