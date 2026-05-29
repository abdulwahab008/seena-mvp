import type { PatternSpec } from './index.js';

export const cambridgePatterns: PatternSpec[] = [
  {
    id: 'cambridge-igcse-paper',
    name: 'Cambridge IGCSE — Paper 2 (Generic)',
    board: 'CAMBRIDGE_IGCSE',
    format: 'paper',
    grade: 10,
    subject: null,
    totalMarks: 80,
    sections: [
      {
        type: 'short',
        title: 'Section A — Structured short answers',
        instructions: 'Answer all questions in the spaces provided.',
        questionCount: 8,
        marksPerQuestion: 4,
      },
      {
        type: 'long',
        title: 'Section B — Extended response',
        instructions: 'Answer all questions. Show all working.',
        questionCount: 4,
        marksPerQuestion: 12,
      },
    ],
    notes: 'Indicative IGCSE Paper 2 layout. Tune per subject (e.g., Physics 0625, Math 0580).',
  },
  {
    id: 'cambridge-o-level-paper',
    name: 'Cambridge O Level — Paper (Generic)',
    board: 'CAMBRIDGE_O_LEVEL',
    format: 'paper',
    grade: 10,
    subject: null,
    totalMarks: 80,
    sections: [
      {
        type: 'mcq',
        title: 'Paper 1 — Multiple Choice',
        instructions: 'Choose the correct option for each question.',
        questionCount: 40,
        marksPerQuestion: 1,
      },
      {
        type: 'short',
        title: 'Paper 2 — Structured Questions',
        instructions: 'Answer all questions.',
        questionCount: 10,
        marksPerQuestion: 4,
      },
    ],
  },
  {
    id: 'cambridge-igcse-quiz',
    name: 'Cambridge IGCSE — Class Quiz',
    board: 'CAMBRIDGE_IGCSE',
    format: 'quiz',
    grade: 10,
    subject: null,
    totalMarks: 12,
    sections: [
      {
        type: 'mcq',
        title: 'Quiz',
        instructions: 'Choose the correct option.',
        questionCount: 8,
        marksPerQuestion: 1,
      },
      {
        type: 'short',
        title: 'Short Answer',
        instructions: 'Answer concisely.',
        questionCount: 2,
        marksPerQuestion: 2,
      },
    ],
  },
];
