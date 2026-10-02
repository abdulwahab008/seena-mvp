import { describe, expect, it } from 'vitest';
import { buildStubPaperSets, diffPaperAgainstPattern, expectedSetCodes, patternTotal, type PaperPattern } from './paper-pattern';

const pattern: PaperPattern = {
  code: 'FBISE-PHY-9',
  board: 'FBISE',
  total_marks: 65,
  sections: [
    { no: 1, name: 'Section A', type: 'mcq', count: 12, marks_each: 1 },
    { no: 2, name: 'Section B', type: 'short', count: 9, marks_each: 3 },
    { no: 3, name: 'Section C', type: 'long', count: 2, marks_each: 13 },
  ],
};

describe('patternTotal', () => {
  it('sums count x marks over the sections (12 + 27 + 26 = 65)', () => {
    expect(patternTotal(pattern.sections)).toBe(65);
  });
});

describe('diffPaperAgainstPattern', () => {
  const paper = () => buildStubPaperSets(pattern, ['Ch.1', 'Ch.2'], 1, 'Physics')[0]!.questions;

  it('accepts a paper that equals the pattern exactly (65 of 65)', () => {
    expect(diffPaperAgainstPattern(pattern, paper())).toBeNull();
  });

  it('names a section with the wrong number of questions', () => {
    expect(diffPaperAgainstPattern(pattern, paper().slice(1))).toBe('section 1 has 11 questions, expected 12');
  });

  it('names a question with the wrong marks', () => {
    const qs = paper();
    qs[qs.length - 1] = { ...qs[qs.length - 1]!, marks: 12 };
    expect(diffPaperAgainstPattern(pattern, qs)).toBe('question 2 of section 3 carries 12 marks, expected 13');
  });

  it('names a question of the wrong type', () => {
    const qs = paper();
    qs[0] = { ...qs[0]!, type: 'short' };
    expect(diffPaperAgainstPattern(pattern, qs)).toBe('question 1 of section 1 is short, expected mcq');
  });

  it('refuses a question outside the pattern even when the counts add up', () => {
    const qs = paper();
    qs[0] = { ...qs[0]!, section_no: 9 };
    expect(diffPaperAgainstPattern(pattern, qs)).toMatch(/section 1 has 11 questions/);
  });
});

describe('buildStubPaperSets', () => {
  it('builds one set per requested set code, each matching the pattern', () => {
    const sets = buildStubPaperSets(pattern, ['Ch.1'], 2, 'Physics');
    expect(sets.map((s) => s.set_code)).toEqual(['A', 'B']);
    for (const s of sets) expect(diffPaperAgainstPattern(pattern, s.questions)).toBeNull();
  });

  it('is deterministic', () => {
    expect(buildStubPaperSets(pattern, ['Ch.1', 'Ch.2'], 1, 'P')).toEqual(buildStubPaperSets(pattern, ['Ch.1', 'Ch.2'], 1, 'P'));
  });

  it('deals the chapters round-robin and never reports a copied question', () => {
    const [set] = buildStubPaperSets(pattern, ['Ch.1', 'Ch.2'], 1, 'P');
    expect(set!.questions.filter((q) => q.section_no === 1).map((q) => q.chapter).slice(0, 3)).toEqual(['Ch.1', 'Ch.2', 'Ch.1']);
    expect(set!.questions.every((q) => q.verbatim_ratio === 0)).toBe(true);
  });

  it('gives MCQs four options and an answer, and nothing else', () => {
    const [set] = buildStubPaperSets(pattern, ['Ch.1'], 1, 'P');
    expect(set!.questions[0]!.options).toHaveLength(4);
    expect(set!.questions.find((q) => q.type === 'long')!.options).toBeUndefined();
  });
});

describe('expectedSetCodes', () => {
  it('runs A, B, ... in order', () => {
    expect(expectedSetCodes(3)).toEqual(['A', 'B', 'C']);
  });
});
