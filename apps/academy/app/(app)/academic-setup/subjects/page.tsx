import { supabaseServer } from '@/lib/supabase/server';
import { SubjectCatalog } from './subject-catalog';

export const dynamic = 'force-dynamic';

const SETUP_ROLES = ['super_admin', 'owner', 'principal', 'exam_controller'];

export default async function SubjectsPage() {
  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: appUser } = user
    ? await supabase.from('app_user').select('app_role').eq('user_id', user.id).single()
    : { data: null };

  const role = appUser?.app_role ?? 'none';
  const canManage = SETUP_ROLES.includes(role);

  const { data: subjects } = await supabase
    .from('subject')
    .select('id, code, name_en, subject_type, is_examinable, default_max_marks, is_active')
    .order('name_en');

  return (
    <SubjectCatalog
      subjects={subjects ?? []}
      canManage={canManage}
    />
  );
}
