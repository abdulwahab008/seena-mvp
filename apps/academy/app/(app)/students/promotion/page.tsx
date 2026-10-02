import { supabaseServer } from '@/lib/supabase/server';
import { PromotionView } from './promotion-view';

export default async function PromotionPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role;
  // Same roles start_session_rollover() itself admits — the RPC is the real
  // gate, this only keeps the surface out of a class teacher's nav.
  const canView = role === 'super_admin' || role === 'owner' || role === 'principal';

  let campuses: Array<{ id: string; name: string }> = [];
  let sessions: Array<{ id: string; name: string }> = [];
  if (canView) {
    const [{ data: campusRows }, { data: sessionRows }] = await Promise.all([
      supabase.from('campus').select('id, name').eq('status', 'active').order('code'),
      supabase.from('academic_session').select('id, name').order('starts_on', { ascending: false }),
    ]);
    campuses = campusRows ?? [];
    sessions = sessionRows ?? [];
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Student promotion</h1>
        <p className="text-sm text-muted-foreground">
          FR-A06 — roll the whole school into the next academic session in one run, with a per-student promote / retain / pass-out
          decision. Enrolments and their new class placements are created only once you drive the run to completion below; nothing
          is written while you are still reviewing the decision list.
        </p>
      </div>
      {canView ? (
        <PromotionView campuses={campuses} sessions={sessions} />
      ) : (
        <p className="text-sm text-muted-foreground">Only a Principal, Owner or Super Admin can run a session rollover.</p>
      )}
    </div>
  );
}
