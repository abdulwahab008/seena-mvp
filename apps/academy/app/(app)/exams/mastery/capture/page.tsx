import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { CaptureBoard } from './capture-board';

/**
 * FR-J07. Where a paper's per-question marks are captured: first the scheme
 * (which question tests which chapter), then each student's marks. A paper
 * that is only ever entered as a total never comes here, and its students'
 * mastery screen says so.
 */
export default async function CapturePage() {
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase
    .from('campus')
    .select('id, name')
    .eq('status', 'active')
    .order('code')
    .limit(1);
  const campus = campuses?.[0];
  const { data: sessions } = campus
    ? await supabase
        .from('academic_session')
        .select('id, name')
        .or(`campus_id.eq.${campus.id},campus_id.is.null`)
        .eq('is_current', true)
        .order('starts_on', { ascending: false })
        .limit(1)
    : { data: null };
  const session = sessions?.[0];
  if (!campus || !session) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Per-question marks</h1>
        <p className="text-sm text-muted-foreground">No current academic session found for this campus.</p>
      </div>
    );
  }

  const { sections } = await readMarkEntryOptions(supabase, campus.id, session.id);
  const { data: papers } = await supabase
    .from('v_exam_subject_section')
    .select('exam_subject_id, section_id, subject_id, exam_term_id')
    .eq('campus_id', campus.id);
  const { data: subjects } = await supabase.from('subject').select('id, name_en');
  const { data: terms } = await supabase.from('v_exam_term_selectable').select('id, name').eq('campus_id', campus.id).eq('session_id', session.id);
  const subjectName = new Map((subjects ?? []).map((s) => [s.id, s.name_en]));
  const termName = new Map((terms ?? []).map((t) => [t.id, t.name]));
  const options = (papers ?? [])
    .filter((p) => p.exam_subject_id && p.section_id && p.subject_id && termName.has(p.exam_term_id ?? ''))
    .map((p) => ({
      examSubjectId: p.exam_subject_id as string,
      sectionId: p.section_id as string,
      label: `${subjectName.get(p.subject_id as string) ?? 'Subject'} — ${termName.get(p.exam_term_id as string) ?? ''}`,
    }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Per-question marks</h1>
        <p className="text-sm text-muted-foreground">
          FR-J07 — define the questions of a paper and the chapter each tests, then capture each student&rsquo;s mark per
          question. This is what{' '}
          <Link href="/exams/mastery" className="underline">
            topic mastery
          </Link>{' '}
          is computed from; a paper entered as one total has no breakdown.
        </p>
      </div>
      <CaptureBoard sections={sections} papers={options} />
    </div>
  );
}
