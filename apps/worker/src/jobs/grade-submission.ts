import { eq } from 'drizzle-orm';
import { Exam, GradedResult } from '@seena/shared';
import { db, schema } from '../db.js';
import { downloadObject } from '../storage.js';
import { extractPagesWithOcr } from '../extract-pipeline.js';
import { llm } from '../openai.js';
import { env } from '../env.js';

export type GradeSubmissionJob = {
  submissionId: string;
  examId: string;
  orgId: string;
};

const GRADER_TOOL_NAME = 'submit_grading';

const GRADER_SYSTEM_PROMPT =
  'You are a rigorous but fair exam grader. You are given the answer key (each question with its correct answer and max marks) and the OCR\'d text of a student\'s answer sheet. For EACH question: locate the student\'s answer in the sheet, compare to the correct answer, and award marks from 0 to the question\'s max. MCQ/true_false: award full marks only if the student\'s choice matches the correct option, else 0. short/long/fill_blank: award partial credit proportional to correctness and completeness. If no answer is found for a question, award 0 with feedback \'No answer found\'. Keep feedback to one short sentence. Never award more than the max.';

const GRADER_TOOL = {
  type: 'function' as const,
  function: {
    name: GRADER_TOOL_NAME,
    description:
      "Submit the graded result for a student's answer sheet. Include one entry per question in the answer key.",
    parameters: {
      type: 'object',
      properties: {
        questions: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              number: { type: 'integer', minimum: 1 },
              section: { type: 'string' },
              type: { type: 'string' },
              max: { type: 'number' },
              awarded: { type: 'number', minimum: 0 },
              studentAnswer: { type: 'string' },
              correctAnswer: { type: 'string' },
              correct: { type: 'boolean' },
              feedback: { type: 'string' },
            },
            required: [
              'number',
              'section',
              'type',
              'max',
              'awarded',
              'studentAnswer',
              'correctAnswer',
              'correct',
              'feedback',
            ],
          },
        },
        totalMax: { type: 'number' },
        totalAwarded: { type: 'number' },
        percentage: { type: 'number' },
        overallFeedback: { type: 'string' },
      },
      required: ['questions', 'totalMax', 'totalAwarded', 'percentage', 'overallFeedback'],
    },
  },
};

// Pricing (USD per 1M tokens). Mirrors apps/web/lib/llm.ts; OpenRouter passes
// through provider rates and reports actual cost per generation for later
// reconciliation.
const PRICING: Record<string, { input: number; output: number }> = {
  'anthropic/claude-sonnet-4.5': { input: 3.0, output: 15.0 },
  'anthropic/claude-opus-4': { input: 15.0, output: 75.0 },
  'anthropic/claude-haiku-4.5': { input: 0.8, output: 4.0 },
  'openai/gpt-4o': { input: 2.5, output: 10.0 },
  'openai/gpt-4o-mini': { input: 0.15, output: 0.6 },
};

function estimateCostUsd(model: string, inputTokens: number, outputTokens: number): number {
  const p = PRICING[model] ?? PRICING['anthropic/claude-sonnet-4.5']!;
  return (inputTokens * p.input + outputTokens * p.output) / 1_000_000;
}

type KeyQuestion = {
  number: number;
  section: string;
  type: string;
  prompt: string;
  correctAnswer: string;
  max: number;
  options?: string[];
};

function buildAnswerKey(exam: Exam): KeyQuestion[] {
  const out: KeyQuestion[] = [];
  let number = 1;
  for (const section of exam.sections) {
    for (const q of section.questions) {
      out.push({
        number,
        section: section.title,
        type: q.type,
        prompt: q.prompt,
        correctAnswer: q.answer,
        max: q.marks,
        options: 'options' in q ? q.options : undefined,
      });
      number += 1;
    }
  }
  return out;
}

function renderAnswerKey(key: KeyQuestion[]): string {
  return key
    .map((q) => {
      const lines = [
        `Q${q.number} [${q.type}] (section: ${q.section}, max marks: ${q.max})`,
        `Question: ${q.prompt}`,
      ];
      if (q.options && q.options.length > 0) {
        lines.push(`Options: ${q.options.join(' | ')}`);
      }
      lines.push(`Correct answer: ${q.correctAnswer}`);
      return lines.join('\n');
    })
    .join('\n\n');
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

export async function gradeSubmission(job: GradeSubmissionJob): Promise<void> {
  const { submissionId, examId, orgId } = job;

  const [submission] = await db
    .select()
    .from(schema.submissions)
    .where(eq(schema.submissions.id, submissionId));
  if (!submission) throw new Error(`submission ${submissionId} not found`);

  if (submission.status === 'graded') {
    console.log(`[grade-submission] ${submissionId} already graded, skipping`);
    return;
  }

  await db
    .update(schema.submissions)
    .set({ status: 'processing', failureReason: null })
    .where(eq(schema.submissions.id, submissionId));

  try {
    const [exam] = await db.select().from(schema.exams).where(eq(schema.exams.id, examId));
    if (!exam) throw new Error(`exam ${examId} not found`);

    const parsedExam = Exam.parse(exam.payload);
    const answerKey = buildAnswerKey(parsedExam);
    if (answerKey.length === 0) {
      throw new Error('exam has no questions to grade');
    }

    const buffer = await downloadObject(submission.storageKey);
    const extracted = await extractPagesWithOcr(buffer, { tag: submissionId });
    const studentSheetText = extracted.pages
      .map((p) => `[page ${p.page}]\n${p.text}`)
      .join('\n\n');

    const model = env().OPENROUTER_MODEL;
    const startedAt = Date.now();

    const userContent = [
      'ANSWER KEY:',
      renderAnswerKey(answerKey),
      '',
      "STUDENT ANSWER SHEET (OCR'd text):",
      studentSheetText.trim().length > 0 ? studentSheetText : '(no text extracted)',
    ].join('\n');

    const completion = await llm().chat.completions.create({
      model,
      max_tokens: 8000,
      messages: [
        { role: 'system', content: GRADER_SYSTEM_PROMPT },
        { role: 'user', content: userContent },
      ],
      tools: [GRADER_TOOL],
      tool_choice: { type: 'function', function: { name: GRADER_TOOL_NAME } },
    });

    const latencyMs = Date.now() - startedAt;

    const toolCall = completion.choices[0]?.message?.tool_calls?.[0];
    if (!toolCall || toolCall.type !== 'function') {
      throw new Error('grader did not return a tool call');
    }

    let raw: Record<string, unknown>;
    try {
      raw = JSON.parse(toolCall.function.arguments);
    } catch (e) {
      throw new Error(`grader tool arguments not valid JSON: ${(e as Error).message}`);
    }

    const keyByNumber = new Map(answerKey.map((q) => [q.number, q]));
    const rawQuestions = Array.isArray(raw.questions)
      ? (raw.questions as Array<Record<string, unknown>>)
      : [];

    const questions = rawQuestions.map((q) => {
      const number = typeof q.number === 'number' ? q.number : 0;
      const keyQ = keyByNumber.get(number);
      const max = keyQ ? keyQ.max : typeof q.max === 'number' ? q.max : 0;
      const rawAwarded = typeof q.awarded === 'number' ? q.awarded : 0;
      const awarded = Math.min(Math.max(rawAwarded, 0), max);
      return {
        number,
        section: keyQ?.section ?? (typeof q.section === 'string' ? q.section : ''),
        type: keyQ?.type ?? (typeof q.type === 'string' ? q.type : ''),
        max,
        awarded,
        studentAnswer: typeof q.studentAnswer === 'string' ? q.studentAnswer : '',
        correctAnswer:
          keyQ?.correctAnswer ?? (typeof q.correctAnswer === 'string' ? q.correctAnswer : ''),
        correct: typeof q.correct === 'boolean' ? q.correct : awarded >= max && max > 0,
        feedback: typeof q.feedback === 'string' ? q.feedback : '',
      };
    });

    const totalAwarded = round2(questions.reduce((sum, q) => sum + q.awarded, 0));
    const totalMax = round2(questions.reduce((sum, q) => sum + q.max, 0));
    const percentage = totalMax > 0 ? Math.round((totalAwarded / totalMax) * 100) : 0;

    const result = GradedResult.parse({
      questions,
      totalMax,
      totalAwarded,
      percentage,
      overallFeedback: typeof raw.overallFeedback === 'string' ? raw.overallFeedback : '',
    });

    await db
      .update(schema.submissions)
      .set({
        status: 'graded',
        totalMarks: Math.round(result.totalMax),
        obtainedMarks: result.totalAwarded.toFixed(2),
        result,
        ocrMethod: extracted.ocrMethod,
        gradedAt: new Date(),
      })
      .where(eq(schema.submissions.id, submissionId));

    const inputTokens = completion.usage?.prompt_tokens ?? 0;
    const outputTokens = completion.usage?.completion_tokens ?? 0;
    const costUsd = estimateCostUsd(model, inputTokens, outputTokens);

    await db.insert(schema.generations).values({
      orgId,
      userId: submission.createdBy,
      examId,
      kind: 'grade-submission',
      model,
      inputTokens,
      outputTokens,
      latencyMs,
      costUsd: costUsd.toFixed(6),
    });

    console.log(
      `[grade-submission] ${submissionId} graded ${result.totalAwarded}/${result.totalMax} (${result.percentage}%)`,
    );
  } catch (err) {
    console.error(`[grade-submission] ${submissionId} failed`, err);
    await db
      .update(schema.submissions)
      .set({ status: 'failed', failureReason: (err as Error).message.slice(0, 500) })
      .where(eq(schema.submissions.id, submissionId));
    throw err;
  }
}
