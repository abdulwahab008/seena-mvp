import { supabaseServer } from '@/lib/supabase/server';
import { MonthlySummaryView } from './monthly-summary-view';

const ADMIN_ROLES = ['super_admin', 'owner', 'principal'];

export default async function MonthlyAttendanceSummaryPage() {
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
    const { data } = await supabase
      .from('class_section')
      .select('id, name, class_level(name_en)')
      .eq('campus_id', campusId)
      .eq('is_active', true);
    sections = (data ?? []).map((s) => ({
      id: s.id,
      label: `${(Array.isArray(s.class_level) ? s.class_level[0] : s.class_level)?.name_en ?? ''} · ${s.name}`,
    }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Monthly Attendance Summary</h1>
        <p className="text-sm text-muted-foreground">
          FR-G14 — per-student working days, present days and attendance % for a section and month.
        </p>
      </div>
      {!campusId ? (
        <p className="text-sm text-muted-foreground">No active campus found.</p>
      ) : sections.length === 0 ? (
        <p className="text-sm text-muted-foreground">No sections found for this campus.</p>
      ) : (
        <MonthlySummaryView campusId={campusId} sections={sections} isAdmin={isAdmin} />
      )}
    </div>
  );
}
