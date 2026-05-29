import { z } from 'zod';
import { QuestionType } from './exam.js';
import { Format } from './format.js';

export const CustomSection = z.object({
  type: QuestionType,
  count: z.number().int().min(1).max(50),
  marks: z.number().min(0.5).max(20).optional(),
});
export type CustomSection = z.infer<typeof CustomSection>;

export const GenerateExamRequest = z.object({
  bookId: z.string().uuid(),
  patternId: z.string().min(1),
  chapter: z.string().nullable().optional(),
  exercise: z.string().nullable().optional(),
  title: z.string().max(200).optional(),
  totalMarksOverride: z.number().int().positive().optional(),
  difficulty: z.enum(['easy', 'medium', 'hard', 'mixed']).default('mixed'),
  language: z.enum(['en', 'ur', 'mixed']).default('en'),
});
export type GenerateExamRequest = z.infer<typeof GenerateExamRequest>;

export const RegenerateQuestionRequest = z.object({
  examId: z.string().uuid(),
  sectionIndex: z.number().int().min(0),
  questionIndex: z.number().int().min(0),
  hint: z.string().optional(),
});
export type RegenerateQuestionRequest = z.infer<typeof RegenerateQuestionRequest>;

const NullableInt = z.preprocess((v) => {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'string') {
    const n = parseInt(v, 10);
    return Number.isFinite(n) ? n : null;
  }
  return v;
}, z.number().int().nullable());

const NullableString = z.preprocess(
  (v) => (v === '' || v === undefined ? null : v),
  z.string().nullable(),
);

const NullableFormat = z.preprocess(
  (v) => (v === '' || v === undefined ? null : v),
  Format.nullable(),
);

export const ParsedIntent = z.object({
  intent: z.enum(['generate', 'regenerate', 'edit', 'explain', 'unknown']),
  bookId: NullableString.refine(
    (v) => v === null || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v),
    { message: 'bookId must be a UUID or null' },
  ),
  chapter: NullableString,
  exercise: NullableString,
  patternId: NullableString,
  format: NullableFormat.default(null),
  totalMarks: NullableInt,
  questionTypes: z.array(QuestionType).default([]),
  customSections: z.array(CustomSection).default([]),
  difficulty: z.enum(['easy', 'medium', 'hard', 'mixed']).default('mixed'),
  rationale: z.string().optional(),
});
export type ParsedIntent = z.infer<typeof ParsedIntent>;
