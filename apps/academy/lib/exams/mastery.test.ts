import { describe, expect, it } from 'vitest';
import {
  gridToRows,
  isLowConfidence,
  isReteach,
  parseMark,
  summaryLine,
  topicLine,
  uncapturedMessage,
  weakestFirst,
  type MasteryTopic,
} from './mastery';

/** FR-J07. The sentences and rules the acceptance criteria quote. */
const topic = (over: Partial<MasteryTopic>): MasteryTopic => ({
  subject_name: 'Physics',
  topic_tag: 'Ch.1 Measurements',
  obtained: 44,
  max_marks: 50,
  pct: 88,
  question_count: 3,
  low_confidence: false,
  ...over,
});

describe('chapter wording', () => {
  it('AC1: "Ch.3 Motion 42%, Ch.1 Measurements 88%" — weakest first', () => {
    const topics = [topic({}), topic({ topic_tag: 'Ch.3 Motion', pct: 42, obtained: 21 })];
    expect(summaryLine(topics)).toBe('Ch.3 Motion 42%, Ch.1 Measurements 88%');
    expect(topicLine(topics[1]!)).toBe('Ch.3 Motion 42%');
  });

  it('rounds to a whole percent and never prints a missing one as zero', () => {
    expect(topicLine({ topic_tag: 'Ch.2 Heat', pct: 74.6 })).toBe('Ch.2 Heat 75%');
    expect(topicLine({ topic_tag: 'Ch.2 Heat', pct: null })).toBe('Ch.2 Heat —');
  });

  it('sorts a chapter with no percentage last, then by name', () => {
    const sorted = weakestFirst([
      { topic_tag: 'B', pct: null },
      { topic_tag: 'A', pct: 60 },
      { topic_tag: 'C', pct: 60 },
    ]);
    expect(sorted.map((t) => t.topic_tag)).toEqual(['A', 'C', 'B']);
  });
});

describe('thresholds', () => {
  it('AC3: below 50% is a re-teach candidate, 50% is not', () => {
    expect(isReteach(49.99)).toBe(true);
    expect(isReteach(50)).toBe(false);
    expect(isReteach(null)).toBe(false);
  });

  it('AC4: fewer than 3 questions is low confidence', () => {
    expect(isLowConfidence(2)).toBe(true);
    expect(isLowConfidence(3)).toBe(false);
  });
});

describe('AC2: explaining the absence', () => {
  it('says the data was not captured, rather than showing an empty chart', () => {
    const msg = uncapturedMessage({ subject_name: 'Chemistry', term_name: 'Final Term', exam_subject_id: 'x', reason: 'no_question_scheme' });
    expect(msg).toContain('per-question data was not captured');
    expect(msg).toContain('Chemistry');
  });

  it('distinguishes a paper with a scheme but no marks for this student', () => {
    const msg = uncapturedMessage({ subject_name: 'Physics', term_name: 'Final Term', exam_subject_id: 'x', reason: 'no_marks_for_candidate' });
    expect(msg).toContain('no per-question marks have been captured for this student');
  });
});

describe('the capture grid', () => {
  it('parses blank as not entered and rejects out-of-range input', () => {
    expect(parseMark('', 10)).toEqual({ value: null, error: null });
    expect(parseMark(' 7.5 ', 10)).toEqual({ value: 7.5, error: null });
    expect(parseMark('11', 10).error).toBe('At most 10');
    expect(parseMark('-1', 10).error).toBe('Cannot be negative');
    expect(parseMark('abc', 10).error).toBe('Enter a number');
  });

  it('sends only cells that were typed, so a blank is not a zero', () => {
    const questions = [
      { questionNo: 1, maxMarks: 10, chapterNo: 1, chapterTitle: 'A' },
      { questionNo: 2, maxMarks: 10, chapterNo: 1, chapterTitle: 'A' },
    ];
    const rows = gridToRows({ e1: { 1: '8', 2: '' }, e2: { 1: '', 2: '' }, e3: { 1: '0', 2: '5' } }, questions);
    expect(rows).toEqual([
      { enrolment_id: 'e1', marks: [{ question_no: 1, obtained: 8 }] },
      { enrolment_id: 'e3', marks: [{ question_no: 1, obtained: 0 }, { question_no: 2, obtained: 5 }] },
    ]);
  });
});
