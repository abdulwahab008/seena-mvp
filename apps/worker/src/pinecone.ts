import { Pinecone } from '@pinecone-database/pinecone';
import { pineconeNamespace } from '@seena/shared/rag/namespace';
import { env } from './env.js';

let _client: Pinecone | null = null;

export function pinecone(): Pinecone {
  if (_client) return _client;
  _client = new Pinecone({ apiKey: env().PINECONE_API_KEY });
  return _client;
}

/**
 * Returns the underlying (non-namespaced) Pinecone Index. Use this when you
 * need to delete or describe across namespaces; chain `.namespace(...)` for
 * per-namespace operations.
 */
export function pineconeIndex() {
  return pinecone().Index(env().PINECONE_INDEX);
}

/**
 * Returns a namespace-scoped Index for the given org and embedding model.
 * If `embeddingModel` is omitted, the legacy `org_<orgId>` namespace is used.
 */
export function getNamespace(orgId: string, embeddingModel?: string | null) {
  return pineconeIndex().namespace(pineconeNamespace(orgId, embeddingModel ?? null));
}

/**
 * Backwards-compatible accessor for the legacy per-org namespace
 * (`org_<orgId>`). Prefer `getNamespace(orgId, embeddingModel)` for new code.
 */
export function orgIndex(orgId: string) {
  return getNamespace(orgId);
}
