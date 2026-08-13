import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '@/lib/database.types';
import type { ExamEntryReadiness } from '@/lib/exams/subject-query';
import type { ExamAbsenceReason, ExamAttendanceStatus, MarkComponentCode, MarkStatus } from '@/lib/validation';

/**
 * FR-I12. The shape fn_mark_entry_sheet() returns: FR-I02's readiness answer
 * (is there a denominator, and what columns) plus everything else one grid
 * needs, in one round trip — because the grid is opened on a 2G phone and a
 * second request is a second chance to fail.
 */
export type MarkEntryStudent = {
  enrolment_id: string;
  roll_no: number | null;
  student_name: string;
  gr_number: string;
  /** Keyed by component. A component with no entry is simply absent here. */
  marks: Partial<Record<MarkComponentCode, number>>;
  status: MarkStatus | null;
  /**
   * FR-I11. Always one of the four values — 'present' when nothing was
   * recorded — so a grid never infers "sat the paper" from an empty cell.
   */
  attendance_status: ExamAttendanceStatus;
  absence_reason: ExamAbsenceReason | null;
  /** 'AB' / 'EX' / 'DEB', or null for a candidate who sat the paper. */
  report_symbol: string | null;
};

/** FR-I16. Null until the set is approved. */
export type MarkLockInfo = {
  locked_at: string;
  locked_by: string | null;
  locked_by_name: string | null;
  unlock_state: 'locked' | 'unlocked';
  candidate_count: number;
  mark_count: number;
  /** FR-I17 AC3: a mark changed inside a break-glass window since sign-off. */
  result_stale_at: string | null;
};

/**
 * FR-I17. Present only while a window is genuinely open — the same
 * clock_timestamp() comparison the write path makes, so the banner and the
 * database cannot disagree about whether the glass is broken.
 */
export type BreakGlassWindow = {
  request_id: string;
  reason: string;
  approved_at: string;
  expires_at: string;
  approved_by_name: string | null;
  requested_by_name: string | null;
};

export type MarkEntrySheet = ExamEntryReadiness & {
  /**
   * FR-I16 folds the lock into this: a locked set is read-only for EVERY
   * caller, the controller who approved it included, so the grid asks one
   * question rather than two.
   */
  can_enter: boolean;
  /** FR-I11: an exemption and a debarment are the exam office's to record. */
  can_exempt: boolean;
  mark_precision: number;
  /** FR-I16. Read-only because it was signed off is not read-only because you do not teach it. */
  is_locked: boolean;
  lock: MarkLockInfo | null;
  /** FR-I17. Non-null means is_locked is true AND the grid is writable anyway. */
  break_glass: BreakGlassWindow | null;
  can_approve: boolean;
  students: MarkEntryStudent[];
};

/**
 * FR-I16. app.fn_mark_completeness()'s answer: what stops this (paper,
 * section) being signed off, named per candidate rather than as a count.
 */
export type MarkCompleteness = {
  components: MarkComponentCode[];
  candidate_count: number;
  mark_count: number;
  /** AC1's candidates: no mark at all, and no exam status either. */
  not_started: { gr_number: string; roll_no: number | null; student_name: string }[];
  partial: {
    gr_number: string;
    roll_no: number | null;
    student_name: string;
    missing: MarkComponentCode[];
  }[];
  complete: boolean;
};

export type MarkApprovalSubject = {
  exam_subject_id: string;
  subject_id: string;
  subject_name: string;
  is_locked: boolean;
  locked_at: string | null;
  locked_by_name: string | null;
  unlock_state: 'locked' | 'unlocked' | null;
  completeness: MarkCompleteness;
};

/** FR-I16 AC4, per class rather than per term — see the migration header. */
export type TermResultReady = {
  exam_term_id: string;
  section_id: string;
  subject_count: number;
  locked_count: number;
  pending_subjects: string[];
  ready: boolean;
  /** FR-I17 AC3. Ready AND stale is the normal state after a correction. */
  stale: boolean;
  stale_subjects: string[];
  stale_at: string | null;
};

/** FR-I17. One row of v_mark_unlock_request — the decision queue. */
export type MarkUnlockRequestRow = {
  id: string;
  exam_subject_id: string;
  section_id: string;
  subject_name: string | null;
  class_name: string | null;
  section_name: string | null;
  reason: string;
  status: 'pending' | 'approved' | 'expired' | 'rejected';
  requested_by: string | null;
  requested_by_name: string | null;
  requested_at: string;
  approved_by_name: string | null;
  approved_at: string | null;
  expires_at: string | null;
  decision_note: string | null;
  edit_count: number;
};

/** FR-I17 AC4's report. */
export type MarkUnlockException = {
  exam_subject_id: string;
  exam_term_name: string | null;
  subject_name: string | null;
  class_name: string | null;
  unlock_count: number;
  sections: string[];
  reasons: string[];
  approvers: string[];
  requesters: string[];
  windows_with_edits: number;
  first_unlocked_at: string | null;
  last_unlocked_at: string | null;
};

export type MarkApprovalQueue = {
  exam_term_id: string;
  section_id: string;
  can_approve: boolean;
  subjects: MarkApprovalSubject[];
  result_ready: TermResultReady;
};

export type MarkSectionOption = { id: string; label: string; classLevelId: string; streamId: string | null };
export type MarkSubjectOption = { subjectId: string; subjectName: string; classLevelId: string };

/**
 * The section and subject pickers. Listing is campus-scoped by RLS; whether
 * this teacher may WRITE any given one is fn_mark_entry_sheet()'s can_enter,
 * and ultimately fn_upsert_marks()'s own gate — never this list.
 */
export async function readMarkEntryOptions(
  supabase: SupabaseClient<Database>,
  campusId: string,
  sessionId: string,
): Promise<{ sections: MarkSectionOption[]; subjects: MarkSubjectOption[] }> {
  const [{ data: sections }, { data: classSubjects }] = await Promise.all([
    supabase
      .from('class_section')
      .select('id, name, class_level_id, stream_id, class_level(name_en, ordinal)')
      .eq('campus_id', campusId)
      .eq('session_id', sessionId)
      .eq('is_active', true),
    supabase
      .from('class_subject')
      .select('class_level_id, subject_id, subject(name_en, is_examinable)')
      .eq('campus_id', campusId)
      .eq('session_id', sessionId),
  ]);

  const sectionOptions = (sections ?? [])
    .map((s) => ({
      id: s.id,
      label: `${s.class_level?.name_en ?? ''} — ${s.name}`,
      classLevelId: s.class_level_id,
      streamId: s.stream_id,
      ordinal: s.class_level?.ordinal ?? 0,
    }))
    .sort((a, b) => a.ordinal - b.ordinal || a.label.localeCompare(b.label))
    .map(({ id, label, classLevelId, streamId }) => ({ id, label, classLevelId, streamId }));

  const seen = new Set<string>();
  const subjectOptions = (classSubjects ?? [])
    // A NON_EXAMINABLE subject has no paper to mark.
    .filter((cs) => cs.subject?.is_examinable !== false)
    .map((cs) => ({
      subjectId: cs.subject_id,
      subjectName: cs.subject?.name_en ?? '',
      classLevelId: cs.class_level_id,
    }))
    .filter((o) => {
      const key = `${o.classLevelId}:${o.subjectId}`;
      return seen.has(key) ? false : (seen.add(key), true);
    })
    .sort((a, b) => a.subjectName.localeCompare(b.subjectName));

  return { sections: sectionOptions, subjects: subjectOptions };
}
