import { Pinecone, type Index } from '@pinecone-database/pinecone';
import { pineconeNamespace } from '@seena/shared/rag/namespace';
import { env } from './env';

declare global {
  // eslint-disable-next-line no-var
  var __pinecone: Pinecone | undefined;
}

export function pinecone(): Pinecone {
  if (globalThis.__pinecone) return globalThis.__pinecone;
  const c = new Pinecone({ apiKey: env().PINECONE_API_KEY });
  globalThis.__pinecone = c;
  return c;
}

export function index(): Index {
  return pinecone().Index(env().PINECONE_INDEX);
}

export function getNamespace(orgId: string, embeddingModel?: string | null) {
  return index().namespace(pineconeNamespace(orgId, embeddingModel));
}

// Backwards-compat shim — used by routes that delete vectors when a book is deleted etc.
export function orgIndex(orgId: string, embeddingModel?: string | null) {
  return getNamespace(orgId, embeddingModel);
}
