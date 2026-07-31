import { supabaseServer } from '@/lib/supabase/server';
import { RegisterForm } from './register-form';

const ADMIN_ROLES = ['super_admin', 'owner', 'principal'];

export default async function AttendanceRegisterPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const isAdmin = !!appUser && ADMIN_ROLES.includes(appUser.app_role);

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  let sections: { id: string; label: string }[] = [];
  if (campusId) {
    if (isAdmin) {
      const { data } = await supabase
        .from('class_section')
        .select('id, name, class_level(name_en)')
        .eq('campus_id', campusId)
        .eq('is_active', true);
      sections = (data ?? []).map((s) => ({
        id: s.id,
        label: `${(Array.isArray(s.class_level) ? s.class_level[0] : s.class_level)?.name_en ?? ''} · ${s.name}`,
      }));
    } else {
      const { data } = await supabase
        .from('section_class_teacher')
        .select('section_id, class_section(id, name, class_level(name_en))')
        .eq('staff_id', user!.id);
      sections = (data ?? [])
        .map((r) => (Array.isArray(r.class_section) ? r.class_section[0] : r.class_section))
        .filter((s): s is NonNullable<typeof s> => !!s)
        .map((s) => ({
          id: s.id,
          label: `${(Array.isArray(s.class_level) ? s.class_level[0] : s.class_level)?.name_en ?? ''} · ${s.name}`,
        }));
    }
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Attendance Register</h1>
        <p className="text-sm text-muted-foreground">FR-G02 — one status per enrolled student per day, holiday- and lock-aware.</p>
      </div>
      {!campusId ? (
        <p className="text-sm text-muted-foreground">No active campus found.</p>
      ) : sections.length === 0 ? (
        <p className="text-sm text-muted-foreground">No section is assigned to you as class teacher.</p>
      ) : (
        <RegisterForm campusId={campusId} sections={sections} />
      )}
    </div>
  );
}
