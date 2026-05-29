/**
 * Chunking strategies and embedding model registry.
 * Used by web (UI dropdowns + validation) and worker (resolution).
 */

import type { ChunkConfig } from './chunk.js';

export type StrategyKey =
  | 'page-aware-200-40'
  | 'page-aware-600-80'
  | 'page-aware-1200-160';

export type StrategyMeta = {
  key: StrategyKey;
  config: ChunkConfig;
  label: string;
  description: string;
};

export const CHUNK_STRATEGIES: Record<StrategyKey, StrategyMeta> = {
  'page-aware-200-40': {
    key: 'page-aware-200-40',
    config: { targetTokens: 200, overlapTokens: 40 },
    label: 'Small (≈200 tokens)',
    description:
      'Fine-grained chunks. Best for narrow retrieval like single-exercise quizzes. More chunks → higher embedding cost but tighter relevance.',
  },
  'page-aware-600-80': {
    key: 'page-aware-600-80',
    config: { targetTokens: 600, overlapTokens: 80 },
    label: 'Default (≈600 tokens)',
    description: 'Balanced. Good general-purpose choice for paper-style generations.',
  },
  'page-aware-1200-160': {
    key: 'page-aware-1200-160',
    config: { targetTokens: 1200, overlapTokens: 160 },
    label: 'Large (≈1200 tokens)',
    description:
      'Long-context chunks. Better for essay/long-question generation; fewer chunks but each carries more surrounding text.',
  },
};

export const DEFAULT_STRATEGY_KEY: StrategyKey = 'page-aware-600-80';

export function resolveStrategyConfig(key: StrategyKey): ChunkConfig {
  return CHUNK_STRATEGIES[key].config;
}

export type EmbeddingModelKey = 'openai/text-embedding-3-large';

export type EmbeddingModelMeta = {
  key: EmbeddingModelKey;
  dimensions: number;
  label: string;
  description: string;
  pinecone_index_dimension: number;
};

/**
 * Embedding models available for new chunkings. Adding more here:
 *   1. Add the entry below.
 *   2. Ensure your Pinecone index supports the dimension OR set up a second index.
 *      (Current `seena-exams` index is 3072-d; only 3072-d models work against it.)
 */
export const EMBEDDING_MODELS: Record<EmbeddingModelKey, EmbeddingModelMeta> = {
  'openai/text-embedding-3-large': {
    key: 'openai/text-embedding-3-large',
    dimensions: 3072,
    label: 'OpenAI text-embedding-3-large',
    description: '3072-d. High quality, current default.',
    pinecone_index_dimension: 3072,
  },
};

export const DEFAULT_EMBEDDING_MODEL_KEY: EmbeddingModelKey = 'openai/text-embedding-3-large';

export function isSupportedEmbeddingModel(model: string): model is EmbeddingModelKey {
  return model in EMBEDDING_MODELS;
}
