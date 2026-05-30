import { z } from 'zod';

/** Per-question grade produced by the auto-grader. */
export const GradedQuestion = z.object({
  number: z.number().int().min(1),
  section: z.string(),
  type: z.string(),
  max: z.number(),
  awarded: z.number().min(0),
  studentAnswer: z.string(),
  correctAnswer: z.string(),
  correct: z.boolean(),
  feedback: z.string(),
});
export type GradedQuestion = z.infer<typeof GradedQuestion>;

export const GradedResult = z.object({
  questions: z.array(GradedQuestion),
  totalMax: z.number(),
  totalAwarded: z.number(),
  percentage: z.number(),
  overallFeedback: z.string(),
});
export type GradedResult = z.infer<typeof GradedResult>;

export const SubmissionStatus = z.enum(['pending', 'processing', 'graded', 'failed']);
export type SubmissionStatus = z.infer<typeof SubmissionStatus>;
