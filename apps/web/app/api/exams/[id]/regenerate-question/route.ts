import { NextResponse } from 'next/server';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { RegenerateQuestionRequest, Exam, Question } from '@seena/shared';
import { llm, estimateCostUsd } from '@/lib/llm';
import { env } from '@/lib/env';
import { formatContext, retrieveChunks } from '@/lib/rag/retrieve';

const QUESTION_TOOL = {
  type: 'function' as const,
  function: {
    name: 'submit_question',
    description: 'Submit one regenerated exam question matching the same type and marks.',
    parameters: {
      type: 'object',
      properties: {
        type: { type: 'string', enum: ['mcq', 'short', 'long', 'fill_blank', 'true_false'] },
        prompt: { type: 'string', minLength: 5 },
        options: { type: 'array', items: { type: 'string' } },
        answer: { type: 'string' },
        marks: { type: 'number' },
        source_pages: { type: 'array', items: { type: 'integer', minimum: 1 }, minItems: 1 },
        explanation: { type: 'string' },
      },
      required: ['type', 'prompt', 'answer', 'marks', 'source_pages'],
    },
  },
};

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const startedAt = Date.now();
  try {
    const { orgId, userId } = await requireSession();
    const { id } = await params;
    const body = RegenerateQuestionRequest.parse({
      ...(await req.json()),
      examId: id,
    });

    const [exam] = await db
      .select()
      .from(schema.exams)
      .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
    if (!exam) return NextResponse.json({ error: 'not found' }, { status: 404 });

    const examPayload = Exam.parse(exam.payload);
    const section = examPayload.sections[body.sectionIndex];
    if (!section) return NextResponse.json({ error: 'bad section index' }, { status: 400 });
    const original = section.questions[body.questionIndex];
    if (!original) return NextResponse.json({ error: 'bad question index' }, { status: 400 });

    const chunks = await retrieveChunks({
      orgId,
      bookId: exam.bookId,
      query: original.prompt,
      topK: 8,
      chapter: exam.chapter,
      exercise: exam.exercise,
    });
    const context = formatContext(chunks);

    const model = env().OPENROUTER_MODEL;
    const completion = await llm().chat.completions.create({
      model,
      max_tokens: 1500,
      messages: [
        {
          role: 'system',
          content:
            'You regenerate a single exam question. Match the original type and marks exactly. Cite source_pages from the provided context. Do not copy 15+ word verbatim spans.',
        },
        {
          role: 'user',
          content: `Section: ${section.title}
Type: ${original.type}
Marks: ${original.marks}
${body.hint ? `Teacher hint: ${body.hint}\n` : ''}
The original question to replace (for style reference; produce a NEW one of the same type and marks):
${original.prompt}

CONTEXT:
${context}`,
        },
      ],
      tools: [QUESTION_TOOL],
      tool_choice: { type: 'function', function: { name: 'submit_question' } },
    });

    const toolCall = completion.choices[0]?.message?.tool_calls?.[0];
    if (!toolCall || toolCall.type !== 'function') throw new Error('no tool call');
    const newQuestion = Question.parse(JSON.parse(toolCall.function.arguments));

    examPayload.sections[body.sectionIndex]!.questions[body.questionIndex] = newQuestion;

    const [updated] = await db
      .update(schema.exams)
      .set({ payload: examPayload, updatedAt: new Date() })
      .where(eq(schema.exams.id, id))
      .returning();

    const inputTokens = completion.usage?.prompt_tokens ?? 0;
    const outputTokens = completion.usage?.completion_tokens ?? 0;

    await db.insert(schema.generations).values({
      orgId,
      userId,
      examId: id,
      kind: 'regenerate-question',
      model,
      inputTokens,
      outputTokens,
      latencyMs: Date.now() - startedAt,
      costUsd: estimateCostUsd(model, inputTokens, outputTokens).toFixed(6),
    });

    return NextResponse.json({ exam: updated, question: newQuestion });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
