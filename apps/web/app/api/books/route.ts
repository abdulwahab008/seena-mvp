import { NextResponse } from 'next/server';
import { z } from 'zod';
import { eq, desc } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { bookProcessQueue } from '@/lib/queue';
import { BookMetadata } from '@seena/shared';
import { getSignedReadUrl } from '@/lib/storage';
import { rateLimit } from '@/lib/ratelimit';
import { assertExamQuota } from '@/lib/quota';
import { apiError } from '@/lib/http';

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
    await rateLimit(`book-create:${orgId}`, 10, 60);
    // Book ingest (OCR + embedding) is the most expensive operation in the
    // product — it must be gated by the same cap as exam generation.
    await assertExamQuota(orgId);
    const body = CreateBody.parse(await req.json());
    // Prevent cross-org file access: the key must live under this org's prefix.
    if (!body.storageKey.startsWith(`org_${orgId}/`)) {
      return NextResponse.json({ error: 'invalid storage key' }, { status: 403 });
    }
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
    return apiError(e);
  }
}
