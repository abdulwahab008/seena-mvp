import { asc, desc, eq } from 'drizzle-orm';
import { randomUUID } from 'node:crypto';
import type { ChunkConfig, PageText } from '@seena/shared/rag/chunk';
import { chunkPages } from '@seena/shared/rag/chunk';
import { db, schema } from '../db.js';
import { extractPagesWithOcr } from '../extract-pipeline.js';
import { embedTexts } from '../openai.js';
import { pineconeIndex } from '../pinecone.js';
import { downloadObject } from '../storage.js';

const MAX_CHUNKS_PER_BOOK = 1500;
const PINECONE_BATCH = 100;

export type BookRechunkJob = {
  chunkingId: string;
  bookId: string;
  orgId: string;
};

type PineconeMetadata = Record<string, string | number | boolean | string[]>;

/**
 * Re-chunk an already-processed book under a new (strategy × embedding model)
 * combo described by an existing `chunkings` row.
 *
 * The pipeline never re-OCRs a book that already has `book_pages`; it only
 * re-extracts for legacy books that pre-date the `book_pages` table.
 */
export async function rechunkBook(job: BookRechunkJob): Promise<void> {
  const { chunkingId, bookId, orgId } = job;

  // 1. Load the chunkings row. Idempotency: bail if it's already ready.
  const [chunking] = await db
    .select()
    .from(schema.chunkings)
    .where(eq(schema.chunkings.id, chunkingId));
  if (!chunking) throw new Error(`chunking ${chunkingId} not found`);
  if (chunking.status === 'ready') {
    console.log(`[book-rechunk] ${chunkingId} already ready, skipping`);
    return;
  }
  if (chunking.bookId !== bookId || chunking.orgId !== orgId) {
    throw new Error(
      `chunking ${chunkingId} does not belong to book ${bookId} / org ${orgId}`,
    );
  }

  try {
    // 2. Load existing book_pages. If empty, this is a legacy book — re-extract
    //    from the PDF once and persist into book_pages so future rechunks are
    //    cheap.
    let pages = await loadBookPages(bookId);
    if (pages.length === 0) {
      pages = await backfillLegacyBookPages(bookId, orgId);
    }
    if (pages.length === 0) {
      throw new Error('no extractable text — book has no pages after backfill');
    }

    // 3. Move into embedding state.
    await db
      .update(schema.chunkings)
      .set({ status: 'embedding', failureReason: null })
      .where(eq(schema.chunkings.id, chunkingId));

    // 4. Chunk according to this chunking's strategy config.
    const strategyConfig = (chunking.strategyConfig ?? {}) as ChunkConfig;
    let chunks = chunkPages(pages, strategyConfig);
    if (chunks.length > MAX_CHUNKS_PER_BOOK) {
      console.warn(
        `[book-rechunk] ${bookId} has ${chunks.length} chunks, capping at ${MAX_CHUNKS_PER_BOOK}`,
      );
      chunks = chunks.slice(0, MAX_CHUNKS_PER_BOOK);
    }
    if (chunks.length === 0) {
      throw new Error('chunking produced 0 chunks — strategy config may be invalid');
    }

    // 5. Embed using the chunking's chosen model.
    const vectors = await embedTexts(
      chunks.map((c) => c.text),
      chunking.embeddingModel,
    );
    if (vectors.length !== chunks.length) {
      throw new Error(`embedding count mismatch: ${vectors.length} vs ${chunks.length}`);
    }

    // 6. Upsert into Pinecone in this chunking's namespace, batched.
    const [book] = await db.select().from(schema.books).where(eq(schema.books.id, bookId));
    if (!book) throw new Error(`book ${bookId} not found`);

    const chunkIds = chunks.map(() => randomUUID());
    const ns = pineconeIndex().namespace(chunking.namespace);
    for (let i = 0; i < chunks.length; i += PINECONE_BATCH) {
      const slice = chunks.slice(i, i + PINECONE_BATCH);
      const ids = chunkIds.slice(i, i + PINECONE_BATCH);
      const vecs = vectors.slice(i, i + PINECONE_BATCH);
      await ns.upsert(
        slice.map((c, j) => {
          const metadata: PineconeMetadata = {
            chunkingId,
            bookId,
            orgId,
            page: c.page,
            chapter: c.chapterLabel ?? '',
            exercise: c.exerciseLabel ?? '',
            text: c.text,
            grade: book.grade ?? -1,
            subject: book.subject,
          };
          return {
            id: ids[j]!,
            values: vecs[j]!,
            metadata,
          };
        }),
      );
    }

    // 7. Replace chunks_meta rows for this chunking and mark ready.
    await db.transaction(async (tx) => {
      await tx
        .delete(schema.chunksMeta)
        .where(eq(schema.chunksMeta.chunkingId, chunkingId));
      await tx.insert(schema.chunksMeta).values(
        chunks.map((c, i) => ({
          id: chunkIds[i]!,
          bookId,
          orgId,
          chunkingId,
          page: c.page,
          chapterLabel: c.chapterLabel,
          exerciseLabel: c.exerciseLabel,
          tokenCount: c.tokenCount,
          text: c.text,
        })),
      );
      await tx
        .update(schema.chunkings)
        .set({ status: 'ready', chunkCount: chunks.length, readyAt: new Date() })
        .where(eq(schema.chunkings.id, chunkingId));
    });

    console.log(
      `[book-rechunk] ${chunkingId} ready (${chunks.length} chunks, ns=${chunking.namespace})`,
    );
  } catch (err) {
    const reason = (err as Error).message.slice(0, 500);
    console.error(`[book-rechunk] ${chunkingId} failed: ${reason}`);
    await db
      .update(schema.chunkings)
      .set({ status: 'failed', failureReason: reason })
      .where(eq(schema.chunkings.id, chunkingId));
    // Re-throw so BullMQ can record the failure.
    throw err;
  }
}

async function loadBookPages(bookId: string): Promise<PageText[]> {
  const rows = await db
    .select({
      pageNumber: schema.bookPages.pageNumber,
      text: schema.bookPages.text,
    })
    .from(schema.bookPages)
    .where(eq(schema.bookPages.bookId, bookId))
    .orderBy(asc(schema.bookPages.pageNumber));
  return rows.map((r) => ({ page: r.pageNumber, text: r.text }));
}

/**
 * One-time backfill for legacy books that were processed before `book_pages`
 * existed. Re-extracts the PDF (with OCR fallback) and inserts page rows so
 * future rechunks read straight from Postgres.
 */
async function backfillLegacyBookPages(bookId: string, orgId: string): Promise<PageText[]> {
  const [book] = await db.select().from(schema.books).where(eq(schema.books.id, bookId));
  if (!book) throw new Error(`book ${bookId} not found`);

  // Resume support: prior attempt may have already persisted some pages.
  // The vision OCR runs in 30-page batches; we tell it to skip whole batches
  // whose final page is already covered.
  const [highest] = await db
    .select({ pageNumber: schema.bookPages.pageNumber })
    .from(schema.bookPages)
    .where(eq(schema.bookPages.bookId, bookId))
    .orderBy(desc(schema.bookPages.pageNumber))
    .limit(1);
  const skipUntil = highest?.pageNumber ?? 0;
  if (skipUntil > 0) {
    console.log(`[book-rechunk] ${bookId} resuming legacy backfill from page ${skipUntil + 1}`);
  } else {
    console.log(
      `[book-rechunk] ${bookId} has no book_pages — backfilling from storage (legacy book)`,
    );
  }

  const buffer = await downloadObject(book.storageKey);
  const visionModel = process.env.OPENROUTER_VISION_MODEL ?? null;
  const visionMethodLabel = visionModel ? `vision-llm-${visionModel}` : 'vision-llm';

  await extractPagesWithOcr(buffer, {
    tag: bookId,
    vision: {
      skipPageNumbersBeforeOrEqual: skipUntil,
      onBatchComplete: async (batchPages) => {
        const rows = batchPages
          .filter((p) => p.text.trim().length > 0)
          .map((p) => ({
            bookId,
            orgId,
            pageNumber: p.page,
            text: p.text,
            ocrMethod: visionMethodLabel,
            ocrModel: visionModel,
          }));
        if (rows.length === 0) return;
        await db.insert(schema.bookPages).values(rows).onConflictDoNothing();
      },
    },
  });

  // Re-load whatever ended up persisted (incremental writes from above plus
  // anything from prior attempts).
  return await loadBookPages(bookId);
}
