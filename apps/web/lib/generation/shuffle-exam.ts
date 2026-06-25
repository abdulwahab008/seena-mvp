import type { Exam } from '@seena/shared';

// Deterministic seeded PRNG (mulberry32) so each version is reproducible — the
// same exam + seed always yields the same shuffle.
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffleInPlace<T>(arr: T[], rand: () => number): void {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [arr[i], arr[j]] = [arr[j]!, arr[i]!];
  }
}

export const VERSION_LABELS = ['A', 'B', 'C', 'D', 'E', 'F'] as const;

/**
 * Anti-leak variant of an exam: questions reordered within each section and
 * MCQ options reshuffled. The `answer` is stored as the full option text (not a
 * letter), so reshuffling options never changes the correct answer — the answer
 * key stays valid by construction.
 */
export function shuffleExam(exam: Exam, seed: number): Exam {
  const rand = mulberry32(seed || 1);
  const next = structuredClone(exam);
  for (const section of next.sections) {
    shuffleInPlace(section.questions, rand);
    for (const q of section.questions) {
      if (q.type === 'mcq') shuffleInPlace(q.options, rand);
    }
  }
  return next;
}
