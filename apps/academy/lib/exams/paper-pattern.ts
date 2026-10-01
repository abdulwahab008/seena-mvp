/**
 * FR-I05. The pure side of paper generation: the shape of a board pattern, the
 * exact-match check the database applies to a worker callback (mirrored here so
 * the development stub worker and the tests use the same rule), and a
 * deterministic stub paper builder.
 *
 * The database is the authority: fn_ingest_generated_paper() re-checks every
 * paper with app.fn_paper_pattern_diff(). This module exists so the stub worker
 * never sends something the database would refuse, and so the rule can be
 * unit-tested without a database.
 */
export type QuestionType = 'mcq' | 'short' | 'long';

export type PatternSection = { no: number; name: string; type: QuestionType; count: number; marks_each: number };

export type PaperPattern = { code: string; board: string; total_marks: number; sections: PatternSection[] };

export type GeneratedQuestion = {
  section_no: number;
  question_no: number;
  type: QuestionType;
  marks: number;
  text: string;
  options?: string[];
  answer?: string;
  chapter?: string;
  topic_tag?: string;
  slo_code?: string;
  source_pages?: number[];
  /** Share of the question that reproduces its source text, 0..1, measured by the worker. */
  verbatim_ratio?: number;
};

export type GeneratedPaperSet = { set_code: string; title: string; questions: GeneratedQuestion[] };

/** Above this, a question counts as a copy of the textbook and the job is blocked. */
export const COPYRIGHT_MAX_RATIO = 0.5;

export function patternTotal(sections: readonly PatternSection[]): number {
  return sections.reduce((sum, s) => sum + s.count * s.marks_each, 0);
}

/** null when the paper matches the pattern exactly, otherwise the first difference as a sentence. */
export function diffPaperAgainstPattern(pattern: Pick<PaperPattern, 'sections'>, questions: readonly GeneratedQuestion[]): string | null {
  let expected = 0;
  for (const s of pattern.sections) {
    const have = questions.filter((q) => q.section_no === s.no).length;
    if (have !== s.count) return `section ${s.no} has ${have} questions, expected ${s.count}`;
    expected += s.count * s.marks_each;
  }
  let total = 0;
  for (const q of questions) {
    const s = pattern.sections.find((x) => x.no === q.section_no);
    if (!s) return `question ${q.question_no} is in section ${q.section_no}, which is not in the pattern`;
    if (q.marks !== s.marks_each) return `question ${q.question_no} of section ${q.section_no} carries ${q.marks} marks, expected ${s.marks_each}`;
    if (q.type !== s.type) return `question ${q.question_no} of section ${q.section_no} is ${q.type}, expected ${s.type}`;
    total += q.marks;
  }
  if (total !== expected) return `paper totals ${total} of ${expected} marks`;
  return null;
}

/** The set codes a job of n sets must return, in order. */
export function expectedSetCodes(setCount: number): string[] {
  return Array.from({ length: setCount }, (_, i) => String.fromCharCode(65 + i));
}

/**
 * A pattern-conforming paper with placeholder question text, deterministic for a
 * given job. This is what the DEVELOPMENT worker returns: it exercises the whole
 * request -> callback -> ingest path without a generation service. Chapters are
 * dealt round-robin across the questions of each section.
 */
export function buildStubPaperSets(pattern: PaperPattern, chapters: readonly string[], setCount: number, title: string): GeneratedPaperSet[] {
  const chapterList = chapters.length > 0 ? chapters : ['Ch.1'];
  return expectedSetCodes(setCount).map((code) => {
    const questions: GeneratedQuestion[] = [];
    for (const s of pattern.sections) {
      for (let n = 1; n <= s.count; n += 1) {
        const chapter = chapterList[(n - 1) % chapterList.length]!;
        questions.push({
          section_no: s.no,
          question_no: n,
          type: s.type,
          marks: s.marks_each,
          text: `[Development stub, set ${code}] ${s.name}, question ${n} on ${chapter}.`,
          options: s.type === 'mcq' ? ['Option A', 'Option B', 'Option C', 'Option D'] : undefined,
          answer: s.type === 'mcq' ? 'A' : undefined,
          chapter,
          topic_tag: chapter,
          source_pages: [],
          verbatim_ratio: 0,
        });
      }
    }
    return { set_code: code, title: `${title} (set ${code})`, questions };
  });
}
