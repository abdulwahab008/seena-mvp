import { supabaseServer } from '@/lib/supabase/server';
import { CompetencyRegistry } from './competency-registry';

export default async function CompetencyPage() {
  const supabase = await supabaseServer();

  const [{ data: staff }, { data: subjects }, { data: classLevels }, { data: competencies }] = await Promise.all([
    supabase.from('staff').select('id, full_name').eq('employment_status', 'active').order('full_name'),
    supabase.from('subject').select('id, name_en').eq('is_active', true).order('name_en'),
    supabase.from('class_level').select('id, name_en, ordinal').eq('is_active', true).order('ordinal'),
    supabase.from('teacher_subject_competency').select('id, staff_id, subject_id, min_class_ordinal, max_class_ordinal, source'),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Teacher competency</h1>
        <p className="text-sm text-muted-foreground">
          FR-E07 — which subjects and class levels each teacher can teach, so allocation and substitution suggestions propose people
          who can actually take the class.
        </p>
      </div>
      <CompetencyRegistry staff={staff ?? []} subjects={subjects ?? []} classLevels={classLevels ?? []} competencies={competencies ?? []} />
    </div>
  );
}
