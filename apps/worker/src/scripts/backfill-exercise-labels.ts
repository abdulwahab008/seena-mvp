import { asc, eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from '@seena/shared/db/schema';
import { env } from '../env.js';
import { getNamespace } from '../pinecone.js';

type ChunkRow = {
  id: string;
  bookId: string;
  orgId: string;
  page: number;
  chapterLabel: string | null;
  exerciseLabel: string | null;
};

type Resolved = {
  id: string;
  chapterLabel: string | null;
  exerciseLabel: string | null;
  dbChanged: boolean;
  chapterChanged: boolean;
  exerciseChanged: boolean;
};

async function withRetry<T>(label: string, fn: () => Promise<T>, attempts = 4): Promise<T> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      const wait = 500 * Math.pow(2, i);
      console.warn(
        `[retry] ${label} attempt ${i + 1} failed: ${(err as Error).message}; waiting ${wait}ms`,
      );
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw lastErr;
}

async function main(): Promise<void> {
  const sql = postgres(env().DATABASE_URL, { max: 5, idle_timeout: 20, prepare: false });
  const db = drizzle(sql, { schema });

  try {
    const readyBooks = await db
      .select({ id: schema.books.id, orgId: schema.books.orgId })
      .from(schema.books)
      .where(eq(schema.books.status, 'ready'));

    for (const book of readyBooks) {
      const rows: ChunkRow[] = await db
        .select({
          id: schema.chunksMeta.id,
          bookId: schema.chunksMeta.bookId,
          orgId: schema.chunksMeta.orgId,
          page: schema.chunksMeta.page,
          chapterLabel: schema.chunksMeta.chapterLabel,
          exerciseLabel: schema.chunksMeta.exerciseLabel,
        })
        .from(schema.chunksMeta)
        .where(eq(schema.chunksMeta.bookId, book.id))
        .orderBy(asc(schema.chunksMeta.page), asc(schema.chunksMeta.id));

      let lastChapter: string | null = null;
      let lastExercise: string | null = null;
      const resolved: Resolved[] = [];

      for (const row of rows) {
        if (row.chapterLabel != null) lastChapter = row.chapterLabel;
        if (row.exerciseLabel != null) lastExercise = row.exerciseLabel;

        const newChapter = row.chapterLabel ?? lastChapter;
        const newExercise = row.exerciseLabel ?? lastExercise;

        const chapterChanged = newChapter !== row.chapterLabel;
        const exerciseChanged = newExercise !== row.exerciseLabel;

        resolved.push({
          id: row.id,
          chapterLabel: newChapter,
          exerciseLabel: newExercise,
          dbChanged: chapterChanged || exerciseChanged,
          chapterChanged,
          exerciseChanged,
        });
      }

      const dbUpdates = resolved.filter((r) => r.dbChanged);
      let chapterFilled = 0;
      let exerciseFilled = 0;
      for (const r of dbUpdates) {
        if (r.chapterChanged) chapterFilled++;
        if (r.exerciseChanged) exerciseFilled++;
      }

      const BATCH = 100;
      for (let i = 0; i < dbUpdates.length; i += BATCH) {
        const slice = dbUpdates.slice(i, i + BATCH);
        for (const u of slice) {
          await db
            .update(schema.chunksMeta)
            .set({ chapterLabel: u.chapterLabel, exerciseLabel: u.exerciseLabel })
            .where(eq(schema.chunksMeta.id, u.id));
        }
      }

      const pineconeUpdates = resolved.filter(
        (r) => r.chapterLabel != null || r.exerciseLabel != null,
      );
      if (pineconeUpdates.length > 0) {
        const ix = getNamespace(book.orgId);
        for (const u of pineconeUpdates) {
          await withRetry(`pinecone update ${u.id}`, () =>
            ix.update({
              id: u.id,
              metadata: {
                chapter: u.chapterLabel ?? '',
                exercise: u.exerciseLabel ?? '',
              },
            }),
          );
        }
      }

      console.log(
        `[${book.id}] backfilled ${dbUpdates.length} chunks (${chapterFilled} chapter, ${exerciseFilled} exercise)`,
      );
    }
  } finally {
    await sql.end();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
