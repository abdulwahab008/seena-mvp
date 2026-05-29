import {
  Exam,
  getPattern,
  RETRIEVAL_POLICY,
  type PatternSpec,
  type CustomSection,
} from '@seena/shared';
import { llm, estimateCostUsd } from '../llm';
import { env } from '../env';
import { GENERATION_SYSTEM_PROMPT, buildGenerationUserPrompt } from '../rag/prompts';
import {
  formatContext,
  getDefaultChunking,
  retrieveChunksWithTelemetry,
} from '../rag/retrieve';
import { EXAM_TOOL, EXAM_TOOL_NAME } from './exam-tool';
import { findCopyrightViolations, dropViolations } from './copyright-guard';

export type GenerateExamInput = {
  orgId: string;
  bookId: string;
  bookTitle: string;
  bookSubject: string;
  bookGrade: number | null;
  /** Pre-resolved pattern (preferred). Falls back to patternId lookup or customSections. */
  pattern?: PatternSpec;
  patternId?: string;
  customSections?: CustomSection[];
  examTitle?: string;
  chapter?: string | null;
  exercise?: string | null;
  difficulty?: 'easy' | 'medium' | 'hard' | 'mixed';
  language?: 'en' | 'ur' | 'mixed';
};

const DEFAULT_MARKS: Record<string, number> = {
  mcq: 1,
  short: 2,
  long: 5,
  fill_blank: 1,
  true_false: 1,
};

const SECTION_TITLES: Record<string, string> = {
  mcq: 'Objective — Multiple Choice',
  short: 'Subjective — Short Questions',
  long: 'Subjective — Long Questions',
  fill_blank: 'Fill in the Blanks',
  true_false: 'True / False',
};

const SECTION_INSTRUCTIONS: Record<string, string> = {
  mcq: 'Encircle the correct option.',
  short: 'Answer concisely.',
  long: 'Answer in detail.',
  fill_blank: 'Fill in each blank with the correct word or phrase.',
  true_false: 'Mark each statement as True or False.',
};

function buildCustomPattern(
  customSections: CustomSection[],
  bookSubject: string,
  bookGrade: number | null,
): PatternSpec {
  const sections = customSections.map((s) => {
    const marks = s.marks ?? DEFAULT_MARKS[s.type] ?? 1;
    return {
      type: s.type,
      title: SECTION_TITLES[s.type] ?? s.type,
      instructions: SECTION_INSTRUCTIONS[s.type] ?? '',
      questionCount: s.count,
      marksPerQuestion: marks,
    };
  });
  const totalMarks = sections.reduce((sum, s) => sum + s.questionCount * s.marksPerQuestion, 0);
  return {
    id: 'custom',
    name: 'Custom Request',
    board: 'OTHER',
    format: 'paper',
    grade: bookGrade,
    subject: bookSubject,
    totalMarks,
    sections,
  };
}

export type GenerateExamResult = {
  exam: Exam;
  pattern: PatternSpec;
  retrievedChunkIds: string[];
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
  model: string;
  copyrightViolationsDropped: number;
};

export async function generateExam(input: GenerateExamInput): Promise<GenerateExamResult> {
  let pattern: PatternSpec | undefined;
  if (input.customSections && input.customSections.length > 0) {
    pattern = buildCustomPattern(input.customSections, input.bookSubject, input.bookGrade);
  } else if (input.pattern) {
    pattern = input.pattern;
  } else if (input.patternId) {
    pattern = getPattern(input.patternId);
    if (!pattern) throw new Error(`unknown pattern: ${input.patternId}`);
  } else {
    throw new Error('must supply either pattern, patternId, or customSections');
  }

  const queryParts = [input.bookSubject];
  if (input.chapter) queryParts.push(`chapter ${input.chapter}`);
  if (input.exercise) queryParts.push(`exercise ${input.exercise}`);
  queryParts.push(`exam questions ${pattern.sections.map((s) => s.type).join(' ')}`);
  const query = queryParts.join(' ');

  const policy = pattern.format ? RETRIEVAL_POLICY[pattern.format] : undefined;
  const topK = policy?.topK ?? 16;

  const chunking = await getDefaultChunking(input.orgId, input.bookId);
  if (!chunking) {
    throw new Error('book is not ready or has no chunking');
  }

  const retrieval = await retrieveChunksWithTelemetry({
    orgId: input.orgId,
    bookId: input.bookId,
    query,
    topK,
    chapter: input.chapter ?? null,
    exercise: input.exercise ?? null,
    // If the user explicitly named an exercise/chapter, narrow regardless of
    // format. The format policy only adds soft narrowing when the user didn't.
    strictExercise: Boolean(input.exercise),
    strictChapter: Boolean(input.chapter && (policy?.preferChapter || input.exercise)),
    rerank: policy?.rerank ?? false,
    chunking,
  });
  const chunks = retrieval.chunks;
  if (chunks.length === 0) {
    throw new Error('no chunks retrieved — book may not be processed yet');
  }
  if (retrieval.rerank) {
    console.log(
      `[retrieve] reranked via ${retrieval.rerank.model}: ${retrieval.rerank.candidateCount} → ${retrieval.rerank.topN} in ${retrieval.rerank.latencyMs}ms (${retrieval.rerank.inputTokens}in/${retrieval.rerank.outputTokens}out tokens)`,
    );
  }

  const context = formatContext(chunks);
  const examTitle =
    input.examTitle ??
    `${input.bookSubject} — ${pattern.name}${input.chapter ? ` (${input.chapter})` : ''}`;

  const userPrompt = buildGenerationUserPrompt({
    pattern,
    bookTitle: input.bookTitle,
    grade: input.bookGrade,
    subject: input.bookSubject,
    language: input.language ?? 'en',
    difficulty: input.difficulty ?? 'mixed',
    context,
    examTitle,
  });

  const model = env().OPENROUTER_MODEL;
  const completion = await llm().chat.completions.create({
    model,
    max_tokens: 8000,
    messages: [
      { role: 'system', content: GENERATION_SYSTEM_PROMPT },
      { role: 'user', content: userPrompt },
    ],
    tools: [EXAM_TOOL],
    tool_choice: { type: 'function', function: { name: EXAM_TOOL_NAME } },
  });

  const toolCall = completion.choices[0]?.message?.tool_calls?.[0];
  if (!toolCall || toolCall.type !== 'function') {
    throw new Error('exam generator did not return a tool call');
  }

  let examRaw: Record<string, unknown>;
  try {
    examRaw = JSON.parse(toolCall.function.arguments);
  } catch (e) {
    throw new Error(`tool arguments not valid JSON: ${(e as Error).message}`);
  }

  // Inject `type` on each question if the model omitted it (it sometimes mirrors section type).
  if (Array.isArray(examRaw.sections)) {
    for (const section of examRaw.sections as Array<Record<string, unknown>>) {
      if (Array.isArray(section.questions)) {
        for (const q of section.questions as Array<Record<string, unknown>>) {
          if (!q.type && typeof section.type === 'string') q.type = section.type;
        }
      }
    }
  }

  const exam = Exam.parse(examRaw);
  const violations = findCopyrightViolations(exam, context);
  const cleanExam = dropViolations(exam, violations);

  const inputTokens = completion.usage?.prompt_tokens ?? 0;
  const outputTokens = completion.usage?.completion_tokens ?? 0;

  const llmCost = estimateCostUsd(model, inputTokens, outputTokens);
  const rerankCost = retrieval.rerank
    ? estimateCostUsd(
        retrieval.rerank.model,
        retrieval.rerank.inputTokens,
        retrieval.rerank.outputTokens,
      )
    : 0;
  return {
    exam: cleanExam,
    pattern,
    retrievedChunkIds: chunks.map((c) => c.id),
    inputTokens,
    outputTokens,
    costUsd: llmCost + rerankCost,
    model,
    copyrightViolationsDropped: violations.length,
  };
}
