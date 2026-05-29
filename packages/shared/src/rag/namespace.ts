/**
 * Pinecone namespace strategy.
 *
 * Legacy chunks (pre-chunking-versioning) live in `org_<orgId>`.
 * New chunkings live in `org_<orgId>__emb_<modelSlug>`, allowing multiple
 * embedding models to coexist for the same org without colliding.
 *
 * Within a namespace, chunks from different chunkings (same embedding model,
 * different strategy) are distinguished by the `chunkingId` metadata field.
 */

export function modelSlug(model: string): string {
  return model.replace(/[^a-zA-Z0-9-]/g, '_');
}

export function pineconeNamespace(orgId: string, embeddingModel?: string | null): string {
  if (!embeddingModel) return `org_${orgId}`;
  return `org_${orgId}__emb_${modelSlug(embeddingModel)}`;
}

export const DEFAULT_EMBEDDING_MODEL = 'openai/text-embedding-3-large';
export const DEFAULT_EMBEDDING_DIMENSIONS = 3072;
export const DEFAULT_CHUNK_STRATEGY = 'page-aware-600-80';
