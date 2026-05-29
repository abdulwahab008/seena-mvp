import { and, eq } from 'drizzle-orm';
import { randomUUID } from 'node:crypto';
import { chunkPages } from '@seena/shared/rag/chunk';
import {
  DEFAULT_CHUNK_STRATEGY,
  DEFAULT_EMBEDDING_DIMENSIONS,
  DEFAULT_EMBEDDING_MODEL,
  pineconeNamespace,
} from '@seena/shared/rag/namespace';
import { db, schema } from '../db.js';
import { downloadObject } from '../storage.js';
import { extractPagesWithOcr } from '../extract-pipeline.js';
import { embedTexts } from '../openai.js';
import { getNamespace, pineconeIndex } from '../pinecone.js';

const MAX_CHUNKS_PER_BOOK = 1500;
const PINECONE_BATCH = 100;

export type BookProcessJob = {
  bookId: string;
  orgId: string;
};

type PineconeMetadata = Record<string, string | number | boolean | string[]>;

export async function processBook(job: BookProcessJob): Promise<void> {
  const { bookId, orgId } = job;

  const [book] = await db.select().from(schema.books).where(eq(schema.books.id, bookId));
  if (!book) throw new Error(`book ${bookId} not found`);

  await db
    .update(schema.books)
    .set({ status: 'processing', failureReason: null })
    .where(eq(schema.books.id, bookId));

  const namespace = pineconeNamespace(orgId, DEFAULT_EMBEDDING_MODEL);
  let chunkingId: string | null = null;

  try {
    // 1. Reset any prior state for this book (idempotency for retries).
    await resetBookState(bookId, namespace);

    // 2. Download + extract pages (with OCR fallback when text is sparse).
    const buffer = await downloadObject(book.storageKey);
    const extracted = await extractPagesWithOcr(buffer, { tag: bookId });
    const { pages, numPages, ocrMethod, ocrModel, needsOcr } = extracted;

    // 3. Persist raw page text. Skip empty pages.
    const pageRows = pages
      .filter((p) => p.text.trim().length > 0)
      .map((p) => ({
        bookId,
        orgId,
        pageNumber: p.page,
        text: p.text,
        ocrMethod: ocrMethod === 'vision-llm' && ocrModel ? `vision-llm-${ocrModel}` : ocrMethod,
        ocrModel,
      }));
    if (pageRows.length > 0) {
      await db.insert(schema.bookPages).values(pageRows);
    }

    // 4. Insert pending chunkings row + demote prior defaults atomically.
    chunkingId = randomUUID();
    await db.transaction(async (tx) => {
      await tx
        .update(schema.chunkings)
        .set({ isDefault: false })
        .where(
          and(eq(schema.chunkings.bookId, bookId), eq(schema.chunkings.isDefault, true)),
        );
      await tx.insert(schema.chunkings).values({
        id: chunkingId!,
        bookId,
        orgId,
        strategy: DEFAULT_CHUNK_STRATEGY,
        strategyConfig: {},
        embeddingModel: DEFAULT_EMBEDDING_MODEL,
        embeddingDimensions: DEFAULT_EMBEDDING_DIMENSIONS,
        namespace,
        chunkCount: 0,
        status: 'pending',
        isDefault: true,
      });
    });

    // 5. Chunk + embed + upsert + persist chunks_meta.
    try {
      let chunks = chunkPages(pages);
      if (chunks.length > MAX_CHUNKS_PER_BOOK) {
        console.warn(
          `[book-process] ${bookId} has ${chunks.length} chunks, capping at ${MAX_CHUNKS_PER_BOOK}`,
        );
        chunks = chunks.slice(0, MAX_CHUNKS_PER_BOOK);
      }
      if (chunks.length === 0) {
        throw new Error('no extractable text — book may be empty or image-only without OCR');
      }

      await db
        .update(schema.chunkings)
        .set({ status: 'embedding' })
        .where(eq(schema.chunkings.id, chunkingId));

      const chunkIds = chunks.map(() => randomUUID());

      const vectors = await embedTexts(chunks.map((c) => c.text));
      if (vectors.length !== chunks.length) {
        throw new Error(`embedding count mismatch: ${vectors.length} vs ${chunks.length}`);
      }

      const ix = getNamespace(orgId, DEFAULT_EMBEDDING_MODEL);
      for (let i = 0; i < chunks.length; i += PINECONE_BATCH) {
        const slice = chunks.slice(i, i + PINECONE_BATCH);
        const ids = chunkIds.slice(i, i + PINECONE_BATCH);
        const vecs = vectors.slice(i, i + PINECONE_BATCH);
        await ix.upsert(
          slice.map((c, j) => {
            const metadata: PineconeMetadata = {
              chunkingId: chunkingId!,
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

      await db.transaction(async (tx) => {
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
          .where(eq(schema.chunkings.id, chunkingId!));
        await tx
          .update(schema.books)
          .set({
            status: 'ready',
            pageCount: numPages,
            chunkCount: chunks.length,
            needsOcr,
            processedAt: new Date(),
          })
          .where(eq(schema.books.id, bookId));
      });

      console.log(
        `[book-process] ${bookId} ready (${chunks.length} chunks, ${numPages} pages, ns=${namespace})`,
      );
    } catch (innerErr) {
      // Mark the chunkings row as failed before bubbling up.
      const reason = (innerErr as Error).message.slice(0, 500);
      await db
        .update(schema.chunkings)
        .set({ status: 'failed', failureReason: reason })
        .where(eq(schema.chunkings.id, chunkingId));
      throw innerErr;
    }
  } catch (err) {
    console.error(`[book-process] ${bookId} failed`, err);
    await db
      .update(schema.books)
      .set({ status: 'failed', failureReason: (err as Error).message.slice(0, 500) })
      .where(eq(schema.books.id, bookId));
    throw err;
  }
}

/**
 * Wipe any partial state from a previous run so retries are deterministic:
 * - Pinecone vectors for this book in the new-style namespace
 * - chunks_meta rows
 * - chunkings rows
 * - book_pages rows
 *
 * NOTE: we only clear the new namespace; legacy `org_<orgId>` data is left
 * alone and continues to be served by older code paths.
 */
async function resetBookState(bookId: string, namespace: string): Promise<void> {
  try {
    await pineconeIndex()
      .namespace(namespace)
      .deleteMany({ bookId: { $eq: bookId } });
  } catch (err) {
    // Pinecone errors when the namespace has no matching records or doesn't
    // exist yet; that's fine for a first-time run. Log and continue.
    console.warn(
      `[book-process] ${bookId} pinecone reset in namespace ${namespace} skipped: ${(err as Error).message}`,
    );
  }

  await db.delete(schema.chunksMeta).where(eq(schema.chunksMeta.bookId, bookId));
  await db.delete(schema.chunkings).where(eq(schema.chunkings.bookId, bookId));
  await db.delete(schema.bookPages).where(eq(schema.bookPages.bookId, bookId));
}
