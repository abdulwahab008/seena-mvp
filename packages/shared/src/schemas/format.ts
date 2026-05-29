import { z } from 'zod';

export const Format = z.enum([
  'paper',
  'quiz',
  'assignment',
  'homework',
  'midterm',
  'final',
  'mocktest',
]);
export type Format = z.infer<typeof Format>;

/**
 * Retrieval policy hints per format. Drives how broad or narrow the
 * vector search is, and how much context the generator is allowed to use.
 *
 * `rerank` enables a cross-encoder rerank pass between Pinecone and the LLM.
 * It's most valuable for broad, multi-section formats (papers, midterms,
 * mocktests). For narrow formats (quiz, homework) the strict exercise filter
 * already gives precise context, so rerank adds latency without payoff.
 */
export const RETRIEVAL_POLICY: Record<
  Format,
  { topK: number; preferExercise: boolean; preferChapter: boolean; rerank: boolean }
> = {
  quiz: { topK: 6, preferExercise: true, preferChapter: true, rerank: false },
  homework: { topK: 8, preferExercise: true, preferChapter: true, rerank: false },
  assignment: { topK: 10, preferExercise: false, preferChapter: true, rerank: true },
  midterm: { topK: 24, preferExercise: false, preferChapter: false, rerank: true },
  paper: { topK: 32, preferExercise: false, preferChapter: false, rerank: true },
  final: { topK: 32, preferExercise: false, preferChapter: false, rerank: true },
  mocktest: { topK: 32, preferExercise: false, preferChapter: false, rerank: true },
};

export const FORMAT_LABELS: Record<Format, string> = {
  paper: 'Paper',
  quiz: 'Quiz',
  assignment: 'Assignment',
  homework: 'Homework',
  midterm: 'Mid-term',
  final: 'Final',
  mocktest: 'Mock Test',
};
