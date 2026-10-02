import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '@/lib/database.types';
import type { MarkComponentCode } from '@/lib/validation';

/**
 * FR-I02. The reads the exam-subject setup screen needs, in one place so
 * the page stays a layout and the shapes stay checked.
 */
export type ExamSubjectRow = {
  id: string;
  classSubjectId: string;
  classLevelId: string;
  className: string;
  streamName: string | null;
  subjectId: string;
  subjectName: string;
  components: { component: MarkComponentCode; maxMarks: number; passMarks: number; sequence: number }[];
  totalMaxMarks: number;
};

export type ClassSubjectOption = {
  id: string;
  classLevelId: string;
  className: string;
  ordinal: number;
  streamName: string | null;
  subjectId: string;
  subjectName: string;
  isConfigured: boolean;
};

/** The shape fn_exam_entry_readiness() returns. AC4's answer. */
export type ExamEntryReadiness = {
  ready: boolean;
  message: string | null;
  exam_subject_id: string | null;
  class_subject_id: string | null;
  total_max_marks: number | null;
  components: { component: MarkComponentCode; max_marks: number; pass_marks: number; sequence: number }[];
};

export async function readExamSubjectSetup(
  supabase: SupabaseClient<Database>,
  campusId: string,
  sessionId: string,
  examTermId: string,
): Promise<{ configured: ExamSubjectRow[]; options: ClassSubjectOption[] }> {
  const [{ data: classSubjects }, { data: examSubjects }] = await Promise.all([
    supabase
      .from('class_subject')
      .select('id, class_level_id, subject_id, stream_id, class_level(name_en, ordinal), subject(name_en, is_examinable), stream(name_en)')
      .eq('campus_id', campusId)
      .eq('session_id', sessionId),
    supabase
      .from('exam_subject')
      .select('id, class_subject_id, exam_subject_component(component, max_marks, pass_marks, sequence)')
      .eq('exam_term_id', examTermId),
  ]);

  const byClassSubject = new Map((examSubjects ?? []).map((e) => [e.class_subject_id, e]));

  const options: ClassSubjectOption[] = (classSubjects ?? [])
    // A NON_EXAMINABLE subject (FR-E04) has no exam configuration to make;
    // upsert_exam_subject() refuses one, so it is not offered either.
    .filter((cs) => cs.subject?.is_examinable !== false)
    .map((cs) => ({
      id: cs.id,
      classLevelId: cs.class_level_id,
      className: cs.class_level?.name_en ?? '',
      ordinal: cs.class_level?.ordinal ?? 0,
      streamName: cs.stream?.name_en ?? null,
      subjectId: cs.subject_id,
      subjectName: cs.subject?.name_en ?? '',
      isConfigured: byClassSubject.has(cs.id),
    }))
    .sort((a, b) => a.ordinal - b.ordinal || a.subjectName.localeCompare(b.subjectName));

  const configured: ExamSubjectRow[] = options
    .filter((o) => o.isConfigured)
    .map((o) => {
      const es = byClassSubject.get(o.id)!;
      const components = (es.exam_subject_component ?? [])
        .map((c) => ({
          component: c.component as MarkComponentCode,
          maxMarks: c.max_marks,
          passMarks: c.pass_marks,
          sequence: c.sequence,
        }))
        .sort((a, b) => a.sequence - b.sequence);
      return {
        id: es.id,
        classSubjectId: o.id,
        classLevelId: o.classLevelId,
        className: o.className,
        streamName: o.streamName,
        subjectId: o.subjectId,
        subjectName: o.subjectName,
        components,
        totalMaxMarks: components.reduce((sum, c) => sum + c.maxMarks, 0),
      };
    });

  return { configured, options };
}
