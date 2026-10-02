import { supabaseServer } from '@/lib/supabase/server';
import { WalkInForm } from './walk-in-form';

export const metadata = {
  title: 'Walk-in Admission Desk — Seena Academy',
};

export default async function WalkInAdmissionPage() {
  const supabase = await supabaseServer();

  const [
    { data: campuses },
    { data: sessions },
    { data: classLevels },
    { data: sections },
    { data: recentStudents },
  ] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id, name').order('starts_on', { ascending: false }),
    supabase.from('class_level').select('id, code, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('class_section').select('id, campus_id, session_id, class_level_id, name').eq('is_active', true),
    supabase
      .from('student')
      .select('id, name_en, gr_number, created_at')
      .is('deleted_at', null)
      .order('created_at', { ascending: false })
      .limit(10),
  ]);

  return (
    <WalkInForm
      campuses={campuses ?? []}
      sessions={sessions ?? []}
      classLevels={classLevels ?? []}
      sections={sections ?? []}
      recentAdmissions={
        (recentStudents ?? []).map((s) => ({
          id: s.id,
          gr_number: s.gr_number ?? '—',
          name_en: s.name_en,
          created_at: s.created_at,
        }))
      }
    />
  );
}
