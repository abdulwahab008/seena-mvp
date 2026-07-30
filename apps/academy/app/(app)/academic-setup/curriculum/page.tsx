import { supabaseServer } from '@/lib/supabase/server';
import { CurriculumMapper } from './curriculum-mapper';

export default async function CurriculumPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const { data: sessions } = await supabase.from('academic_session').select('id').order('starts_on', { ascending: false }).limit(1);
  const campusId = campuses?.[0]?.id;
  const sessionId = sessions?.[0]?.id;

  const [{ data: classLevels }, { data: subjects }, { data: mappings }, { data: weeklyLoad }] = await Promise.all([
    supabase.from('class_level').select('id, code, name_en, ordinal').eq('is_active', true).order('ordinal'),
    supabase.from('subject').select('id, code, name_en').eq('is_active', true).order('name_en'),
    campusId && sessionId
      ? supabase
          .from('class_subject')
          .select('id, class_level_id, subject_id, weekly_periods, is_compulsory, elective_bucket')
          .eq('campus_id', campusId)
          .eq('session_id', sessionId)
      : Promise.resolve({ data: [] as never[] }),
    campusId && sessionId
      ? supabase
          .from('v_class_weekly_period_load')
          .select('class_level_id, total_weekly_periods')
          .eq('campus_id', campusId)
          .eq('session_id', sessionId)
          .is('stream_id', null)
      : Promise.resolve({ data: [] as never[] }),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Curriculum mapping</h1>
        <p className="text-sm text-muted-foreground">FR-E06 — declare which subjects each class offers and how many periods a week each needs.</p>
      </div>
      {!campusId || !sessionId ? (
        <p className="text-sm text-muted-foreground">No active campus or session found.</p>
      ) : (
        <CurriculumMapper
          campusId={campusId}
          sessionId={sessionId}
          classLevels={classLevels ?? []}
          subjects={subjects ?? []}
          mappings={mappings ?? []}
          weeklyLoad={weeklyLoad ?? []}
        />
      )}
    </div>
  );
}
