import { describe, expect, it } from 'vitest';
import { buildAnswerKeyHtml, buildQuestionPaperHtml, paperFileName, type PaperPrintPayload } from './paper-html';

const payload = (setCode: string): PaperPrintPayload => ({
  schoolName: 'Seena Public School',
  className: 'Class 9',
  subjectNameEn: 'Physics',
  subjectNameUr: 'طبیعیات',
  termName: 'First Term',
  setCode,
  setCount: 2,
  totalMarks: 4,
  sections: [{ no: 1, name: 'Section A', type: 'mcq', count: 2, marks_each: 2 }],
  items: [
    { section_no: 1, question_no: 2, question_type: 'mcq', marks: 2, question_text: 'Second <question>', options: ['one', 'two'], answer: 'B' },
    { section_no: 1, question_no: 1, question_type: 'mcq', marks: 2, question_text: 'First question', options: null, answer: null },
  ],
});

describe('paperFileName', () => {
  it('carries the kind, the subject and the set code (AC4)', () => {
    expect(paperFileName('key', 'Physics', 'B')).toBe('answer-key-physics-set-b.pdf');
    expect(paperFileName('paper', 'Computer Science', 'A')).toBe('question-paper-computer-science-set-a.pdf');
  });

  it('gives Set A and Set B keys different names', () => {
    expect(paperFileName('key', 'Physics', 'A')).not.toBe(paperFileName('key', 'Physics', 'B'));
  });

  it('falls back to a safe slug for a subject with no latin letters', () => {
    expect(paperFileName('key', 'طبیعیات', 'C')).toBe('answer-key-paper-set-c.pdf');
  });
});

describe('question paper', () => {
  it('prints the set code in the header and the footer', () => {
    const { html } = buildQuestionPaperHtml(payload('B'), null);
    expect(html).toContain('data-set="B">SET B');
    expect(html).toContain('Question paper · Set B');
  });

  it('lists questions in order with marks and options, and escapes markup', () => {
    const { html } = buildQuestionPaperHtml(payload('A'), null);
    expect(html.indexOf('First question')).toBeLessThan(html.indexOf('Second'));
    expect(html).toContain('Second &lt;question&gt;');
    expect(html).toContain('<li>one</li>');
    expect(html).toContain('Section A — 2 × 2 = 4 marks');
  });

  it('prints just the letter for a single-set paper', () => {
    const p = { ...payload('A'), setCount: 1 };
    expect(buildQuestionPaperHtml(p, null).html).toContain('data-set="A">A<');
  });
});

describe('answer key', () => {
  it('names its set in the title, the heading and the footer', () => {
    const { html } = buildAnswerKeyHtml(payload('B'), null);
    expect(html).toContain('<title>Answer key — Set B</title>');
    expect(html).toContain('ANSWER KEY — SET B');
    expect(html).toContain('Answer key · Set B');
  });

  it('shows each answer and a dash where there is none', () => {
    const { html } = buildAnswerKeyHtml(payload('A'), null);
    expect(html).toContain('<td>Q2</td><td>2</td><td>B</td>');
    expect(html).toContain('<td>Q1</td><td>2</td><td>—</td>');
  });

  it('is a different document for each set', () => {
    expect(buildAnswerKeyHtml(payload('A'), null).html).not.toBe(buildAnswerKeyHtml(payload('B'), null).html);
  });
});
