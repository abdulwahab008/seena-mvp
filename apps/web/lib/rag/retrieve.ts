import { and, desc, eq } from 'drizzle-orm';
import { db, schema } from '../db';
import { index } from '../pinecone';
import { embedQuery } from './embed';
import { rerank, type RerankTelemetry } from './rerank';

export type RetrievedChunk = {
  id: string;
  score: number;
  text: string;
  page: number;
  chapterLabel: string | null;
  exerciseLabel: string | null;
  bookId: string;
};

export type DefaultChunking = {
  id: string;
  namespace: string;
  embeddingModel: string;
};

export type RetrieveOptions = {
  orgId: string;
  bookId: string;
  query: string;
  topK?: number;
  chapter?: string | null;
  exercise?: string | null;
  /** When true and `exercise` is provided, drop chunks whose label doesn't match. */
  strictExercise?: boolean;
  /** When true and `chapter` is provided, drop chunks whose chapter label doesn't match. */
  strictChapter?: boolean;
  /**
   * Pre-resolved chunking — caller may pass it in to skip an extra DB query.
   * If omitted, retrieveChunks looks up the book's default chunking itself.
   */
  chunking?: DefaultChunking;
  /**
   * When true, over-fetch from Pinecone and re-score with the cross-encoder
   * reranker. No-ops gracefully if `COHERE_API_KEY` is unset.
   */
  rerank?: boolean;
};

export type RetrieveResult = {
  chunks: RetrievedChunk[];
  rerank?: RerankTelemetry;
};

function normalize(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9.]/g, '');
}

function labelMatches(label: string | null, needle: string): boolean {
  if (!label) return false;
  return normalize(label).includes(normalize(needle));
}

/** Generate likely metadata-label variants for a user-typed reference like "1.2". */
function exerciseVariants(input: string): string[] {
  const trimmed = input.trim().replace(/^exercise\s*/i, '');
  return [
    `EXERCISE ${trimmed}`,
    `Exercise ${trimmed}`,
    `exercise ${trimmed}`,
    `EX ${trimmed}`,
    `Ex. ${trimmed}`,
    `Q.${trimmed}`,
    trimmed,
  ];
}

/**
 * Legacy chunkings (pre-namespacing) live in `org_<orgId>` and have no
 * `chunkingId` in their Pinecone metadata. New chunkings live in
 * `org_<orgId>__emb_<modelSlug>`. We detect legacy by absence of `__emb_`.
 */
function isLegacyNamespace(namespace: string): boolean {
  return !namespace.includes('__emb_');
}

/**
 * Look up the default chunking for a book within an org. Returns null if no
 * default chunking exists yet (e.g. book is still processing).
 */
export async function getDefaultChunking(
  orgId: string,
  bookId: string,
): Promise<DefaultChunking | null> {
  const rows = await db
    .select({
      id: schema.chunkings.id,
      namespace: schema.chunkings.namespace,
      embeddingModel: schema.chunkings.embeddingModel,
    })
    .from(schema.chunkings)
    .where(
      and(
        eq(schema.chunkings.bookId, bookId),
        eq(schema.chunkings.orgId, orgId),
        eq(schema.chunkings.isDefault, true),
      ),
    )
    .orderBy(desc(schema.chunkings.createdAt))
    .limit(1);
  const row = rows[0];
  if (!row) return null;
  return { id: row.id, namespace: row.namespace, embeddingModel: row.embeddingModel };
}

export async function retrieveChunks(opts: RetrieveOptions): Promise<RetrievedChunk[]> {
  const r = await retrieveChunksWithTelemetry(opts);
  return r.chunks;
}

export async function retrieveChunksWithTelemetry(
  opts: RetrieveOptions,
): Promise<RetrieveResult> {
  const {
    orgId,
    bookId,
    query,
    topK = 12,
    chapter,
    exercise,
    strictExercise = false,
    strictChapter = false,
    rerank: wantRerank = false,
  } = opts;

  const chunking = opts.chunking ?? (await getDefaultChunking(orgId, bookId));
  if (!chunking) {
    throw new Error('book is not ready or has no chunking');
  }

  const legacy = isLegacyNamespace(chunking.namespace);
  const baseFilter: Record<string, unknown> = legacy
    ? { bookId }
    : { bookId, chunkingId: chunking.id };

  const vec = await embedQuery(query, chunking.embeddingModel);
  const ix = index().namespace(chunking.namespace);

  const mapMatches = (matches: unknown[] | undefined): RetrievedChunk[] =>
    (matches ?? [])
      .filter((m): m is { id: string; score?: number; metadata?: Record<string, unknown> } =>
        Boolean((m as { metadata?: unknown })?.metadata),
      )
      .map((m) => {
        const md = m.metadata as Record<string, unknown>;
        return {
          id: m.id,
          score: m.score ?? 0,
          text: String(md.text ?? ''),
          page: Number(md.page ?? 0),
          chapterLabel: (md.chapter as string | null) ?? null,
          exerciseLabel: (md.exercise as string | null) ?? null,
          bookId: String(md.bookId ?? ''),
        };
      });

  // Rerank is always available now (uses OpenRouter, which is required).
  const rerankActive = wantRerank;

  // Strict path: Pinecone-side metadata filter on exercise label variants.
  if (strictExercise && exercise) {
    const variants = exerciseVariants(exercise);
    const strictPoolSize = rerankActive ? Math.max(topK * 4, 50) : topK;
    const strictRes = await ix.query({
      vector: vec,
      topK: strictPoolSize,
      includeMetadata: true,
      filter: { ...baseFilter, exercise: { $in: variants } },
    });
    const strictChunks = mapMatches(strictRes.matches as unknown[]);
    if (strictChunks.length >= Math.min(topK, 3)) {
      return await maybeRerank(query, strictChunks, topK, rerankActive);
    }
  }

  // Broad path: bookId-only filter, with extra over-fetch when reranking or
  // post-filtering by exercise/chapter.
  const overFetch = rerankActive
    ? Math.max(topK * 4, 50)
    : strictExercise || strictChapter
      ? Math.max(topK * 6, 60)
      : topK;
  const res = await ix.query({
    vector: vec,
    topK: overFetch,
    includeMetadata: true,
    filter: baseFilter,
  });
  let chunks = mapMatches(res.matches as unknown[]);

  if (strictExercise && exercise) {
    const matched = chunks.filter((c) => labelMatches(c.exerciseLabel, exercise));
    if (matched.length >= 1) chunks = matched;
  }
  if (strictChapter && chapter) {
    const matched = chunks.filter((c) => labelMatches(c.chapterLabel, chapter));
    if (matched.length >= 3) chunks = matched;
  }

  return await maybeRerank(query, chunks, topK, rerankActive);
}

async function maybeRerank(
  query: string,
  chunks: RetrievedChunk[],
  topK: number,
  active: boolean,
): Promise<RetrieveResult> {
  if (!active || chunks.length <= 1) {
    return { chunks: chunks.slice(0, topK) };
  }
  try {
    const { results, telemetry } = await rerank(
      query,
      chunks.map((c) => ({ id: c.id, text: c.text })),
      { topN: topK },
    );
    const byId = new Map(chunks.map((c) => [c.id, c]));
    const reranked: RetrievedChunk[] = [];
    for (const r of results) {
      const c = byId.get(r.id);
      if (c) reranked.push({ ...c, score: r.score });
    }
    return { chunks: reranked.slice(0, topK), rerank: telemetry };
  } catch (err) {
    // Reranker failures shouldn't break retrieval — fall back to vector order.
    console.warn('[retrieve] rerank failed, using vector order', err);
    return { chunks: chunks.slice(0, topK) };
  }
}

/**
 * Build a prompt-ready context string with [page X] citation markers.
 * Truncates each chunk to keep total under `maxChars`.
 */
export function formatContext(chunks: RetrievedChunk[], maxChars = 24_000): string {
  let acc = '';
  for (const c of chunks) {
    const part = `[page ${c.page}${c.chapterLabel ? ` | ${c.chapterLabel}` : ''}]\n${c.text}\n\n`;
    if (acc.length + part.length > maxChars) break;
    acc += part;
  }
  return acc.trim();
}
