import { supabaseServer } from '@/lib/supabase/server';
import { CollectionReportView } from './collection-report-view';

export default async function CollectionReportsPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role;
  const canView = role === 'super_admin' || role === 'owner' || role === 'accountant' || role === 'principal';
  const canFinalise = role === 'super_admin' || role === 'owner' || role === 'accountant';

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code');
  const campus = campuses?.[0];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Daily collection report</h1>
        <p className="text-sm text-muted-foreground">
          FR-K29 — ties exactly to the ledger by value_date. A reversal always lands in the day it was posted, never rewriting an
          earlier, already-reported day.
        </p>
      </div>
      {canView && campus ? (
        <CollectionReportView campusId={campus.id} canFinalise={canFinalise} />
      ) : (
        <p className="text-sm text-muted-foreground">
          {campus ? 'Only an Accountant, Principal, Owner, or Super Admin can view collection reports.' : 'No active campus found.'}
        </p>
      )}
    </div>
  );
}
