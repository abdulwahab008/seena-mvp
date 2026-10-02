import { NextResponse } from 'next/server';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { GenerateExamRequest } from '@seena/shared';
import { generateExam } from '@/lib/generation/generate-exam';
import { assertExamQuota } from '@/lib/quota';
import { rateLimit } from '@/lib/ratelimit';
import { apiError } from '@/lib/http';

export async function POST(req: Request) {
  const startedAt = Date.now();
  try {
    const { userId, orgId } = await requireSession();
    await rateLimit(`generate:${orgId}`, 15, 60);
    const body = GenerateExamRequest.parse(await req.json());

    await assertExamQuota(orgId);

    const [book] = await db
      .select()
      .from(schema.books)
      .where(and(eq(schema.books.id, body.bookId), eq(schema.books.orgId, orgId)));
    if (!book) return NextResponse.json({ error: 'book not found' }, { status: 404 });
    if (book.status !== 'ready') {
      return NextResponse.json(
        { error: `book not ready (status=${book.status})` },
        { status: 409 },
      );
    }

    const result = await generateExam({
      orgId,
      userId,
      bookId: book.id,
      bookTitle: book.title,
      bookSubject: book.subject,
      bookGrade: book.grade,
      patternId: body.patternId,
      examTitle: body.title,
      chapter: body.chapter ?? null,
      exercise: body.exercise ?? null,
      difficulty: body.difficulty,
      language: body.language,
    });

    const [exam] = await db
      .insert(schema.exams)
      .values({
        orgId,
        createdBy: userId,
        bookId: book.id,
        title: result.exam.title,
        patternId: result.pattern.id,
        totalMarks: result.exam.total_marks,
        chapter: body.chapter ?? null,
        exercise: body.exercise ?? null,
        difficulty: body.difficulty,
        language: body.language,
        status: 'draft',
        payload: result.exam,
      })
      .returning();
    if (!exam) throw new Error('failed to insert exam');

    await db.insert(schema.generations).values({
      orgId,
      userId,
      examId: exam.id,
      kind: 'generate-exam',
      model: result.model,
      inputTokens: result.inputTokens,
      outputTokens: result.outputTokens,
      latencyMs: Date.now() - startedAt,
      costUsd: result.costUsd.toFixed(6),
    });

    return NextResponse.json({
      exam,
      copyrightViolationsDropped: result.copyrightViolationsDropped,
    });
  } catch (e) {
    return apiError(e);
  }
}
