import { supabaseServer } from '@/lib/supabase/server';
import { AbsenteeNotificationsView } from './absentee-notifications-view';

const ADMIN_ROLES = ['super_admin', 'owner', 'principal'];

export default async function AbsenteeNotificationsPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const isAdmin = !!appUser && ADMIN_ROLES.includes(appUser.app_role);

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Absentee Notifications</h1>
        <p className="text-sm text-muted-foreground">
          FR-G12 — one SMS per absent student per day to the primary guardian, with an exception list for the office.
        </p>
      </div>
      {!campusId ? (
        <p className="text-sm text-muted-foreground">No active campus found.</p>
      ) : (
        <AbsenteeNotificationsView campusId={campusId} isAdmin={isAdmin} />
      )}
    </div>
  );
}
