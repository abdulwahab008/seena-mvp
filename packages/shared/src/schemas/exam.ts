import { z } from 'zod';

export const QuestionType = z.enum([
  'mcq',
  'short',
  'long',
  'fill_blank',
  'true_false',
]);
export type QuestionType = z.infer<typeof QuestionType>;

export const McqQuestion = z.object({
  type: z.literal('mcq'),
  prompt: z.string().min(5),
  options: z.array(z.string().min(1)).min(2).max(6),
  answer: z.string().min(1),
  marks: z.number().min(0.5).max(20),
  source_pages: z.array(z.number().int().min(1)).min(1),
  explanation: z.string().optional(),
});
export type McqQuestion = z.infer<typeof McqQuestion>;

export const ShortQuestion = z.object({
  type: z.literal('short'),
  prompt: z.string().min(5),
  answer: z.string().min(1),
  marks: z.number().min(0.5).max(20),
  source_pages: z.array(z.number().int().min(1)).min(1),
  explanation: z.string().optional(),
});
export type ShortQuestion = z.infer<typeof ShortQuestion>;

export const LongQuestion = z.object({
  type: z.literal('long'),
  prompt: z.string().min(5),
  answer: z.string().min(1),
  marks: z.number().min(0.5).max(40),
  source_pages: z.array(z.number().int().min(1)).min(1),
  explanation: z.string().optional(),
  rubric: z.string().optional(),
});
export type LongQuestion = z.infer<typeof LongQuestion>;

export const FillBlankQuestion = z.object({
  type: z.literal('fill_blank'),
  prompt: z.string().min(5),
  answer: z.string().min(1),
  marks: z.number().min(0.5).max(5),
  source_pages: z.array(z.number().int().min(1)).min(1),
});
export type FillBlankQuestion = z.infer<typeof FillBlankQuestion>;

export const TrueFalseQuestion = z.object({
  type: z.literal('true_false'),
  prompt: z.string().min(5),
  answer: z.enum(['true', 'false']),
  marks: z.number().min(0.5).max(5),
  source_pages: z.array(z.number().int().min(1)).min(1),
  explanation: z.string().optional(),
});
export type TrueFalseQuestion = z.infer<typeof TrueFalseQuestion>;

export const Question = z.discriminatedUnion('type', [
  McqQuestion,
  ShortQuestion,
  LongQuestion,
  FillBlankQuestion,
  TrueFalseQuestion,
]);
export type Question = z.infer<typeof Question>;

export const ExamSection = z.object({
  type: QuestionType,
  title: z.string().min(1),
  instructions: z.string().min(1),
  questions: z.array(Question).min(1),
});
export type ExamSection = z.infer<typeof ExamSection>;

export const Exam = z.object({
  title: z.string().min(1).max(200),
  total_marks: z.number().int().positive(),
  pattern: z.string().min(1),
  sections: z.array(ExamSection).min(1),
});
export type Exam = z.infer<typeof Exam>;
