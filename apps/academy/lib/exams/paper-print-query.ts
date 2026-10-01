import type { SupabaseClient } from '@supabase/supabase-js';
import type { PaperPrintItem, PaperPrintPayload, PaperPrintSection } from './paper-html';

const one = <T>(v: T | T[] | null | undefined): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

/**
 * Reads everything the printed paper and key need, as the signed-in user, so the
 * paper's own row-level security (requester or exam office of the campus) decides
 * whether this returns anything.
 */
export async function loadPaperPrintPayload(supabase: SupabaseClient, paperId: string): Promise<PaperPrintPayload | null> {
  const { data: paper } = await supabase
    .from('exam_paper')
    .select(
      'id, set_code, total_marks, pattern_snapshot, exam_subject_id, campus:campus_id(name), exam_subject:exam_subject_id(term:exam_term_id(name), class_subject:class_subject_id(class_level:class_level_id(name_en), subject:subject_id(name_en, name_ur)))',
    )
    .eq('id', paperId)
    .maybeSingle();
  if (!paper) return null;
  const { data: items } = await supabase
    .from('exam_paper_item')
    .select('section_no, question_no, question_type, marks, question_text, options, answer')
    .eq('paper_id', paperId)
    .order('section_no')
    .order('question_no');
  const { data: group } = await supabase.from('exam_paper_set_group').select('set_count').eq('exam_subject_id', paper.exam_subject_id).maybeSingle();
  const es = one(paper.exam_subject);
  const cs = es ? one(es.class_subject) : null;
  const subject = cs ? one(cs.subject) : null;
  return {
    schoolName: one(paper.campus)?.name ?? 'School',
    className: (cs ? one(cs.class_level)?.name_en : null) ?? '',
    subjectNameEn: subject?.name_en ?? 'Subject',
    subjectNameUr: subject?.name_ur ?? null,
    termName: (es ? one(es.term)?.name : null) ?? '',
    setCode: paper.set_code,
    setCount: group?.set_count ?? 1,
    totalMarks: paper.total_marks,
    sections: ((paper.pattern_snapshot as { sections?: PaperPrintSection[] } | null)?.sections ?? []) as PaperPrintSection[],
    items: (items ?? []).map((i): PaperPrintItem => ({ ...i, options: Array.isArray(i.options) ? (i.options as string[]) : null })),
  };
}
