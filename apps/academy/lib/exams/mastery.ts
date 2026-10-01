/**
 * FR-J07. The pure parts of topic mastery: how a chapter is worded, how the
 * list is ordered, and how a capture grid becomes the rows save_question_marks
 * takes. Kept away from React and the database so the wording the acceptance
 * criteria quote ("Ch.3 Motion 42%, Ch.1 Measurements 88%") and the 50% /
 * 3-question rules are tested directly.
 */
export type MasteryTopic = {
  subject_id?: string;
  subject_name: string;
  topic_tag: string;
  obtained: number;
  max_marks: number;
  pct: number | null;
  question_count: number;
  low_confidence: boolean;
};

export type UncapturedPaper = {
  subject_name: string;
  term_name: string;
  exam_subject_id: string;
  reason: 'no_question_scheme' | 'no_marks_for_candidate';
};

export type MasterySheet = {
  enrolment_id: string;
  student_name: string;
  has_breakdown: boolean;
  topics: MasteryTopic[];
  uncaptured: UncapturedPaper[];
};

export const RETEACH_BELOW_PCT = 50;
export const LOW_CONFIDENCE_BELOW_QUESTIONS = 3;

/** "Ch.3 Motion 42%" — whole percent, as a teacher says it. */
export function topicLine(t: Pick<MasteryTopic, 'topic_tag' | 'pct'>): string {
  return `${t.topic_tag} ${t.pct === null ? '—' : `${Math.round(t.pct)}%`}`;
}

/** The weakest chapter first: that is the one a teacher reads for. */
export function weakestFirst<T extends { pct: number | null; topic_tag: string }>(topics: T[]): T[] {
  return [...topics].sort((a, b) => (a.pct ?? 101) - (b.pct ?? 101) || a.topic_tag.localeCompare(b.topic_tag));
}

export function summaryLine(topics: MasteryTopic[]): string {
  return weakestFirst(topics).map(topicLine).join(', ');
}

export const isReteach = (pct: number | null) => pct !== null && pct < RETEACH_BELOW_PCT;
export const isLowConfidence = (questionCount: number) => questionCount < LOW_CONFIDENCE_BELOW_QUESTIONS;

/** AC2's sentence — what the screen says where there is no breakdown. */
export function uncapturedMessage(p: UncapturedPaper): string {
  return p.reason === 'no_question_scheme'
    ? `${p.subject_name} (${p.term_name}): per-question data was not captured for this paper, so there is no topic breakdown.`
    : `${p.subject_name} (${p.term_name}): no per-question marks have been captured for this student yet.`;
}

export type CaptureQuestion = { questionNo: number; maxMarks: number; chapterNo: number | null; chapterTitle: string };

/** Parse a grid cell: blank is "not entered", anything else must be a number inside the question. */
export function parseMark(raw: string, max: number): { value: number | null; error: string | null } {
  const text = raw.trim();
  if (text === '') return { value: null, error: null };
  const n = Number(text);
  if (!Number.isFinite(n)) return { value: null, error: 'Enter a number' };
  if (n < 0) return { value: null, error: 'Cannot be negative' };
  if (n > max) return { value: null, error: `At most ${max}` };
  return { value: Math.round(n * 100) / 100, error: null };
}

/** The grid -> the RPC's rows. A blank cell sends nothing rather than a zero. */
export function gridToRows(
  grid: Record<string, Record<number, string>>,
  questions: CaptureQuestion[],
): { enrolment_id: string; marks: { question_no: number; obtained: number }[] }[] {
  const rows: { enrolment_id: string; marks: { question_no: number; obtained: number }[] }[] = [];
  for (const [enrolmentId, cells] of Object.entries(grid)) {
    const marks: { question_no: number; obtained: number }[] = [];
    for (const q of questions) {
      const parsed = parseMark(cells[q.questionNo] ?? '', q.maxMarks);
      if (parsed.value !== null) marks.push({ question_no: q.questionNo, obtained: parsed.value });
    }
    if (marks.length > 0) rows.push({ enrolment_id: enrolmentId, marks });
  }
  return rows;
}

export function masteryError(message: string): string {
  if (message.includes('QUESTIONS_LOCKED')) return 'Marks have already been captured against this scheme, so its questions can no longer change.';
  if (message.includes('QUESTIONS_EXCEED_PAPER')) return 'The questions add up to more than the paper’s maximum.';
  if (message.includes('QUESTION_TOPIC_REQUIRED')) return 'Every question needs a chapter.';
  if (message.includes('QUESTION_INVALID')) return 'Question numbers must be unique, positive, and each worth some marks.';
  if (message.includes('QUESTIONS_REQUIRED')) return 'Add at least one question.';
  if (message.includes('NO_QUESTION_SCHEME')) return 'Define the paper’s questions and chapters first.';
  if (message.includes('MARKS_OUT_OF_RANGE')) return 'A mark is above the question’s maximum.';
  if (message.includes('ENROLMENT_NOT_FOUND')) return 'That student is no longer in this section.';
  if (message.includes('EXAM_SUBJECT_NOT_FOUND')) return 'Paper not found.';
  if (message.includes('FORBIDDEN')) return 'You are not assigned to this section and subject.';
  return 'Could not save.';
}
