import type { PatternSpec } from '@seena/shared';

export const GENERATION_SYSTEM_PROMPT = `You are an expert exam paper generator for school and college teachers in Pakistan.

ABSOLUTE RULES:
1. Generate questions ONLY from the provided context. If the context is insufficient for a section, omit questions rather than fabricate facts.
2. EVERY question must include a non-empty "source_pages" array citing the page numbers from the context that support it.
3. NEVER copy 15 or more consecutive words verbatim from the context. Paraphrase and reformulate.
4. Match the requested pattern exactly — section names, question counts, and marks per question.
5. For MCQs: provide exactly 4 options unless the pattern specifies otherwise. The "answer" must be the full text of the correct option, not a letter.
6. Difficulty should match what the requested grade level expects.
7. Output strictly valid JSON conforming to the provided tool schema. No prose outside the JSON.`;

export type GenerationContext = {
  pattern: PatternSpec;
  bookTitle: string;
  grade: number | null;
  subject: string;
  language: 'en' | 'ur' | 'mixed';
  difficulty: 'easy' | 'medium' | 'hard' | 'mixed';
  context: string;
  examTitle: string;
};

export function buildGenerationUserPrompt(g: GenerationContext): string {
  const sectionsBrief = g.pattern.sections
    .map(
      (s, i) =>
        `${i + 1}. ${s.title} — ${s.questionCount} × ${s.type.toUpperCase()} questions, ${s.marksPerQuestion} mark(s) each. Instructions: ${s.instructions}`,
    )
    .join('\n');

  return `Generate an exam paper.

EXAM TITLE: ${g.examTitle}
BOOK: ${g.bookTitle}
GRADE: ${g.grade ?? 'unspecified'}
SUBJECT: ${g.subject}
PATTERN: ${g.pattern.name} (${g.pattern.id})
TOTAL MARKS: ${g.pattern.totalMarks}
DIFFICULTY: ${g.difficulty}
LANGUAGE: ${g.language}

PATTERN SECTIONS (must match exactly):
${sectionsBrief}

CONTEXT FROM TEXTBOOK (cite page numbers from these markers):
---
${g.context}
---

Generate the exam now using the provided tool. Every question must have a "source_pages" array.`;
}

export const INTENT_PARSER_SYSTEM = `You parse a teacher's natural-language request for exam generation into a strict JSON object. The teacher may name a book, chapter, exercise, pattern, difficulty, or specific question counts in any phrasing.

CUSTOM COUNTS: If the teacher specifies counts (e.g. "5 MCQs", "4 short questions", "10 questions and 2 long ones"), populate customSections accordingly. Each section is { type, count, marks? }. Mappings:
- "MCQ", "multiple choice", "objective" → type "mcq"
- "short question", "short Q", "brief" → type "short"
- "long question", "essay", "detailed" → type "long"
- "fill in the blank", "fill blank" → type "fill_blank"
- "true/false", "T/F" → type "true_false"
- Bare "questions" without type → assume "short"

If the teacher describes a board pattern WITHOUT specifying counts (e.g. "FBISE 9th paper" or "full Punjab Board paper"), leave customSections empty and set patternId.

FORMAT: extract format if user says quiz, assignment, paper, midterm, final, mock test, etc. Mappings:
- "quiz", "quick quiz", "pop quiz" → "quiz"
- "assignment" → "assignment"
- "homework", "home work", "HW" → "homework"
- "midterm", "mid-term", "mid term" → "midterm"
- "final", "final exam", "finals" → "final"
- "mock test", "mocktest", "mock paper" → "mocktest"
- "paper", "exam paper", "test paper", "board paper" or unspecified → "paper"

CHAPTER: extract the top-level structural unit. Books call this many things:
- "Chapter 5", "Unit 3", "Lesson 5", "Topic 5", "Module 5" → chapter: "5"
- "Lesson 5: The Selfish Giant" → chapter: "5" (drop the title — we filter by id)

EXERCISE: extract any sub-section identifier WITHIN a chapter. Mappings:
- "exercise 1.2", "ex 1.2" → exercise: "1.2"
- "review exercise 3", "miscellaneous exercise 3" → exercise: "review 3"
- "numerical problems 3.2" → exercise: "numerical 3.2"
- "conceptual questions" → exercise: "conceptual"
- "comprehension", "vocabulary", "composition", "grammar", "discussion" → exercise: "<word>"
- "activity 5" → exercise: "activity 5"
- "past paper 0625/22" → exercise: "past paper 0625/22"

If the user names a *named* section (e.g. "Comprehension" in an English book), keep the word as the exercise string — retrieval matches it case-insensitively.`;

export function buildIntentParserPrompt(message: string, knownBooks: { id: string; title: string; subject: string; grade: number | null }[]): string {
  const bookList = knownBooks.length
    ? knownBooks.map((b) => `- ${b.id}: "${b.title}" (grade ${b.grade ?? '?'}, ${b.subject})`).join('\n')
    : '(no books uploaded yet)';
  return `User message:
"""
${message}
"""

Available books in the user's library:
${bookList}

Parse into JSON with these fields:
- intent: "generate" | "regenerate" | "edit" | "explain" | "unknown"
- bookId: string | null  (must match an id from the list above)
- chapter: string | null
- exercise: string | null
- patternId: string | null  (e.g. "fbise-ssc-physics", "punjab-ssc-generic")
- format: "paper" | "quiz" | "assignment" | "homework" | "midterm" | "final" | "mocktest" | null
- totalMarks: integer | null
- questionTypes: array of "mcq" | "short" | "long" | "fill_blank" | "true_false"
- difficulty: "easy" | "medium" | "hard" | "mixed"
- rationale: short string explaining your interpretation

If the user did not specify, leave fields null. Do NOT invent a bookId.`;
}
