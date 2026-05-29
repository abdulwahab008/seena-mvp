import type { PatternSpec } from './index.js';

export const pindiPatterns: PatternSpec[] = [
  {
    id: 'pindi-ssc-paper',
    name: 'BISE Rawalpindi SSC — Annual Paper',
    board: 'PINDI',
    format: 'paper',
    grade: 9,
    subject: null,
    totalMarks: 75,
    sections: [
      {
        type: 'mcq',
        title: 'Objective Part',
        instructions: 'Encircle the correct option.',
        questionCount: 12,
        marksPerQuestion: 1,
      },
      {
        type: 'short',
        title: 'Subjective — Short Questions',
        instructions: 'Answer briefly.',
        questionCount: 14,
        marksPerQuestion: 2,
      },
      {
        type: 'long',
        title: 'Subjective — Long Questions',
        instructions: 'Answer in detail.',
        questionCount: 3,
        marksPerQuestion: 5,
      },
    ],
    notes: 'BISE Rawalpindi follows Punjab Curriculum closely; pattern is comparable to Punjab Board.',
  },
  {
    id: 'pindi-ssc-midterm',
    name: 'BISE Rawalpindi SSC — Mid-term',
    board: 'PINDI',
    format: 'midterm',
    grade: 9,
    subject: null,
    totalMarks: 40,
    sections: [
      {
        type: 'mcq',
        title: 'Objective',
        instructions: 'Encircle the correct option.',
        questionCount: 8,
        marksPerQuestion: 1,
      },
      {
        type: 'short',
        title: 'Short Questions',
        instructions: 'Answer concisely.',
        questionCount: 7,
        marksPerQuestion: 2,
      },
      {
        type: 'long',
        title: 'Long Questions',
        instructions: 'Answer in detail.',
        questionCount: 2,
        marksPerQuestion: 9,
      },
    ],
  },
  {
    id: 'pindi-ssc-quiz',
    name: 'BISE Rawalpindi SSC — Class Quiz',
    board: 'PINDI',
    format: 'quiz',
    grade: 9,
    subject: null,
    totalMarks: 10,
    sections: [
      {
        type: 'mcq',
        title: 'Quiz',
        instructions: 'Encircle the correct option.',
        questionCount: 10,
        marksPerQuestion: 1,
      },
    ],
  },
];
