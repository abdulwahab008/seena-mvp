import { NextResponse } from 'next/server';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import { Question } from '@seena/shared';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { rateLimit } from '@/lib/ratelimit';
import { apiError } from '@/lib/http';

const Body = z.object({ examId: z.string().uuid(), question: Question });

export async function POST(req: Request) {
  try {
    const { userId, orgId } = await requireSession();
    await rateLimit(`bank:${orgId}`, 60, 60);
    const body = Body.parse(await req.json());

    // Derive subject/board/grade from the exam's book so saved questions are filterable.
    const [exam] = await db
      .select({ bookId: schema.exams.bookId, chapter: schema.exams.chapter })
      .from(schema.exams)
      .where(and(eq(schema.exams.id, body.examId), eq(schema.exams.orgId, orgId)));
    if (!exam) return NextResponse.json({ error: 'exam not found' }, { status: 404 });

    const [book] = await db
      .select({
        subject: schema.books.subject,
        board: schema.books.board,
        grade: schema.books.grade,
      })
      .from(schema.books)
      .where(eq(schema.books.id, exam.bookId));

    const [row] = await db
      .insert(schema.bankQuestions)
      .values({
        orgId,
        createdBy: userId,
        sourceExamId: body.examId,
        subject: book?.subject ?? null,
        board: book?.board ?? null,
        grade: book?.grade ?? null,
        chapter: exam.chapter ?? null,
        type: body.question.type,
        payload: body.question,
      })
      .returning();
    return NextResponse.json({ question: row });
  } catch (e) {
    return apiError(e);
  }
}
