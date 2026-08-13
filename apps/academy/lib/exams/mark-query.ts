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

export type MarkEntrySheet = ExamEntryReadiness & {
  can_enter: boolean;
  /** FR-I11: an exemption and a debarment are the exam office's to record. */
  can_exempt: boolean;
  mark_precision: number;
  students: MarkEntryStudent[];
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
