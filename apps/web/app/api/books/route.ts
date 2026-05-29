import { NextResponse } from 'next/server';
import { z } from 'zod';
import { eq, desc } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { bookProcessQueue } from '@/lib/queue';
import { BookMetadata } from '@seena/shared';
import { getSignedReadUrl } from '@/lib/storage';

const CreateBody = BookMetadata.extend({
  storageKey: z.string().min(1),
});

export async function GET() {
  const { orgId } = await requireSession();
  const rows = await db
    .select()
    .from(schema.books)
    .where(eq(schema.books.orgId, orgId))
    .orderBy(desc(schema.books.createdAt));
  return NextResponse.json({ books: rows });
}

export async function POST(req: Request) {
  try {
    const { userId, orgId } = await requireSession();
    const body = CreateBody.parse(await req.json());
    const sourceUrl = await getSignedReadUrl(body.storageKey, 60 * 60 * 24);
    const [book] = await db
      .insert(schema.books)
      .values({
        orgId,
        uploadedBy: userId,
        title: body.title,
        grade: body.grade,
        subject: body.subject,
        board: body.board,
        language: body.language,
        sourceUrl,
        storageKey: body.storageKey,
        status: 'processing',
      })
      .returning();
    if (!book) throw new Error('failed to insert book');
    await bookProcessQueue().add('process', { bookId: book.id, orgId }, {
      attempts: 3,
      backoff: { type: 'exponential', delay: 30_000 },
      removeOnComplete: true,
      removeOnFail: 100,
    });
    return NextResponse.json({ book });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
