/**
 * Reject any question whose prompt or answer contains a 15+ word verbatim
 * substring from the source context. Returns the indexes of offending questions
 * by section, plus a sanitized exam if you want to drop them.
 */

import type { Exam } from '@seena/shared';

const MIN_WINDOW = 15;

function normalize(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^\w\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function hasSharedNGram(needle: string, haystack: string, n = MIN_WINDOW): boolean {
  const a = normalize(needle).split(' ').filter(Boolean);
  const b = normalize(haystack).split(' ').filter(Boolean);
  if (a.length < n || b.length < n) return false;
  const set = new Set<string>();
  for (let i = 0; i + n <= b.length; i++) set.add(b.slice(i, i + n).join(' '));
  for (let i = 0; i + n <= a.length; i++) {
    if (set.has(a.slice(i, i + n).join(' '))) return true;
  }
  return false;
}

export type CopyrightViolation = {
  sectionIndex: number;
  questionIndex: number;
  field: 'prompt' | 'answer';
};

export function findCopyrightViolations(exam: Exam, sourceContext: string): CopyrightViolation[] {
  const violations: CopyrightViolation[] = [];
  exam.sections.forEach((section, si) => {
    section.questions.forEach((q, qi) => {
      if (hasSharedNGram(q.prompt, sourceContext)) {
        violations.push({ sectionIndex: si, questionIndex: qi, field: 'prompt' });
      }
      const answer = (q as { answer?: string }).answer;
      if (typeof answer === 'string' && hasSharedNGram(answer, sourceContext)) {
        violations.push({ sectionIndex: si, questionIndex: qi, field: 'answer' });
      }
    });
  });
  return violations;
}

export function dropViolations(exam: Exam, violations: CopyrightViolation[]): Exam {
  if (violations.length === 0) return exam;
  const drop = new Set(violations.map((v) => `${v.sectionIndex}:${v.questionIndex}`));
  return {
    ...exam,
    sections: exam.sections.map((s, si) => ({
      ...s,
      questions: s.questions.filter((_, qi) => !drop.has(`${si}:${qi}`)),
    })),
  };
}
