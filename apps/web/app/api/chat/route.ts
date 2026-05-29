import { NextResponse } from 'next/server';
import { z } from 'zod';
import { eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { parseIntent } from '@/lib/generation/parse-intent';
import { generateExam } from '@/lib/generation/generate-exam';
import { resolvePattern } from '@/lib/patterns/resolver';
import type { Board } from '@seena/shared';

const Body = z.object({ message: z.string().min(1).max(2000) });

export async function POST(req: Request) {
  const startedAt = Date.now();
  try {
    const { userId, orgId } = await requireSession();
    const body = Body.parse(await req.json());

    const books = await db
      .select({
        id: schema.books.id,
        title: schema.books.title,
        subject: schema.books.subject,
        grade: schema.books.grade,
      })
      .from(schema.books)
      .where(eq(schema.books.orgId, orgId));

    const parsed = await parseIntent(body.message, books);

    if (parsed.intent.intent !== 'generate' || !parsed.intent.bookId) {
      return NextResponse.json({
        kind: 'message',
        intent: parsed.intent,
        message:
          parsed.intent.bookId === null
            ? 'Tell me which book to use. You can say e.g. "from Physics 9 Punjab Board".'
            : 'I can only generate new exams in this MVP. Try: "Generate an FBISE 9th Physics paper from Chapter 2".',
      });
    }

    const [book] = await db
      .select()
      .from(schema.books)
      .where(eq(schema.books.id, parsed.intent.bookId));
    if (!book || book.orgId !== orgId) {
      return NextResponse.json({ error: 'book not found in your library' }, { status: 404 });
    }
    if (book.status !== 'ready') {
      return NextResponse.json({
        kind: 'message',
        intent: parsed.intent,
        message: `That book is still ${book.status}. Try again in a moment.`,
      });
    }

    const useCustom = parsed.intent.customSections && parsed.intent.customSections.length > 0;

    const resolved = useCustom
      ? null
      : await resolvePattern(orgId, {
          patternId: parsed.intent.patternId,
          format: parsed.intent.format,
          board: book.board as Board,
          grade: book.grade,
          subject: book.subject,
        });

    if (!useCustom && !resolved) {
      return NextResponse.json({
        kind: 'message',
        intent: parsed.intent,
        message:
          "I couldn't match a pattern for that request. Try naming a board (e.g. \"FBISE 9th paper\") or specify counts like \"5 MCQs and 4 short questions\".",
      });
    }

    const result = await generateExam({
      orgId,
      bookId: book.id,
      bookTitle: book.title,
      bookSubject: book.subject,
      bookGrade: book.grade,
      pattern: resolved ?? undefined,
      customSections: useCustom ? parsed.intent.customSections : undefined,
      chapter: parsed.intent.chapter,
      exercise: parsed.intent.exercise,
      difficulty: parsed.intent.difficulty,
      language: book.language as 'en' | 'ur' | 'mixed',
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
        chapter: parsed.intent.chapter,
        exercise: parsed.intent.exercise,
        difficulty: parsed.intent.difficulty,
        language: book.language,
        status: 'draft',
        payload: result.exam,
      })
      .returning();
    if (!exam) throw new Error('failed to insert exam');

    await db.insert(schema.generations).values({
      orgId,
      userId,
      examId: exam.id,
      kind: 'chat-generate-exam',
      model: result.model,
      inputTokens: result.inputTokens + parsed.inputTokens,
      outputTokens: result.outputTokens + parsed.outputTokens,
      latencyMs: Date.now() - startedAt,
      costUsd: (result.costUsd + parsed.costUsd).toFixed(6),
    });

    return NextResponse.json({
      kind: 'exam',
      intent: parsed.intent,
      exam,
      copyrightViolationsDropped: result.copyrightViolationsDropped,
    });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}

