import { z } from 'zod';
import { QuestionType } from '../schemas/exam.js';
import { Board } from '../schemas/book.js';
import { Format } from '../schemas/format.js';
import { fbisePatterns } from './fbise.js';
import { punjabPatterns } from './punjab.js';
import { pindiPatterns } from './pindi.js';
import { cambridgePatterns } from './cambridge.js';

export const PatternSection = z.object({
  type: QuestionType,
  title: z.string(),
  instructions: z.string(),
  questionCount: z.number().int().positive(),
  marksPerQuestion: z.number().positive(),
});
export type PatternSection = z.infer<typeof PatternSection>;

export const PatternSpec = z.object({
  id: z.string(),
  name: z.string(),
  board: Board,
  format: Format.default('paper'),
  grade: z.number().int().nullable(),
  subject: z.string().nullable(),
  totalMarks: z.number().int().positive(),
  sections: z.array(PatternSection).min(1),
  notes: z.string().optional(),
});
export type PatternSpec = z.infer<typeof PatternSpec>;

export const ALL_PATTERNS: PatternSpec[] = [
  ...fbisePatterns,
  ...punjabPatterns,
  ...pindiPatterns,
  ...cambridgePatterns,
];

export function getPattern(id: string): PatternSpec | undefined {
  return ALL_PATTERNS.find((p) => p.id === id);
}

export function listPatterns(filter?: {
  board?: PatternSpec['board'];
  format?: PatternSpec['format'];
  grade?: number;
  subject?: string;
}): PatternSpec[] {
  return ALL_PATTERNS.filter((p) => {
    if (filter?.board && p.board !== filter.board) return false;
    if (filter?.format && p.format !== filter.format) return false;
    if (filter?.grade != null && p.grade != null && p.grade !== filter.grade) return false;
    if (filter?.subject && p.subject && p.subject.toLowerCase() !== filter.subject.toLowerCase())
      return false;
    return true;
  });
}

/**
 * Score how well a pattern fits a target (board / format / grade / subject).
 * Used to pick the best built-in or custom pattern when the user describes
 * a desired exam without naming a specific pattern id.
 */
export function scorePattern(
  pattern: PatternSpec,
  target: {
    board?: PatternSpec['board'];
    format?: PatternSpec['format'];
    grade?: number;
    subject?: string;
  },
): number {
  let score = 0;
  if (target.board && pattern.board === target.board) score += 4;
  if (target.format && pattern.format === target.format) score += 4;
  if (target.grade != null && pattern.grade === target.grade) score += 2;
  if (
    target.subject &&
    pattern.subject &&
    pattern.subject.toLowerCase() === target.subject.toLowerCase()
  )
    score += 2;
  // Generic patterns (subject=null) act as fallbacks.
  if (target.subject && pattern.subject === null) score += 1;
  return score;
}
