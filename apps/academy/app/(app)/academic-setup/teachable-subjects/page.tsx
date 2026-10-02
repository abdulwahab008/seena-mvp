import { supabaseServer } from '@/lib/supabase/server';
import { CreateTeachableSubjectForm } from './create-teachable-subject-form';
import { TeachableSubjectList, type GrantRow } from './teachable-subject-list';

export default async function TeachableSubjectsPage() {
  const supabase = await supabaseServer();

  const { data: staff } = await supabase
    .from('app_user')
    .select('user_id, full_name')
    .in('app_role', ['subject_teacher', 'class_teacher', 'head_of_department'])
    .order('full_name');
  const { data: subjects } = await supabase.from('subject').select('id, code, name_en').eq('is_active', true).order('name_en');
  const { data: classLevels } = await supabase.from('class_level').select('id, code, name_en, ordinal').eq('is_active', true).order('ordinal');
  const { data: streams } = await supabase.from('stream').select('id, code, name_en').eq('is_active', true).order('code');

  const { data: grants } = await supabase
    .from('staff_teachable_subject')
    .select(
      'id, staff:staff_id(full_name), subject:subject_id(code, name_en), class_level_from:class_level_from_id(name_en), class_level_to:class_level_to_id(name_en), stream:stream_id(name_en)',
    )
    .order('created_at', { ascending: false });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Teachable Subjects</h1>
        <p className="text-sm text-muted-foreground">
          FR-D03 — which subjects and grades each teacher is approved to teach. The timetable builder blocks an
          out-of-scope assignment unless a Principal overrides it with a reason.
        </p>
      </div>
      <CreateTeachableSubjectForm staff={staff ?? []} subjects={subjects ?? []} classLevels={classLevels ?? []} streams={streams ?? []} />
      <TeachableSubjectList grants={(grants ?? []) as unknown as GrantRow[]} />
    </div>
  );
}
