import { supabaseServer } from '@/lib/supabase/server';
import { isTenantWideRole } from '@/lib/campus-scope';
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

  // FR-A12 AC2: the campus filter must offer exactly the campuses this
  // caller can see, not every campus in the tenant — public.campus's own
  // RLS policy is tenant-wide only (no campus_id scoping), so a Principal
  // scoped to one campus is derived from their own user_campus rows
  // instead of the raw campus table.
  const campuses =
    role && isTenantWideRole(role)
      ? ((await supabase.from('campus').select('id, code, name').eq('status', 'active').order('code')).data ?? [])
      : await (async () => {
          const { data: scoped } = await supabase.from('user_campus').select('campus_id').eq('user_id', user!.id).eq('is_active', true);
          const ids = (scoped ?? []).map((r) => r.campus_id);
          if (ids.length === 0) return [];
          const { data } = await supabase.from('campus').select('id, code, name').in('id', ids).eq('status', 'active').order('code');
          return data ?? [];
        })();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Daily collection report</h1>
        <p className="text-sm text-muted-foreground">
          FR-K29 — ties exactly to the ledger by value_date. A reversal always lands in the day it was posted, never rewriting an
          earlier, already-reported day.
        </p>
      </div>
      {canView && campuses.length > 0 ? (
        <CollectionReportView campuses={campuses} canFinalise={canFinalise} />
      ) : (
        <p className="text-sm text-muted-foreground">
          {campuses.length > 0
            ? 'Only an Accountant, Principal, Owner, or Super Admin can view collection reports.'
            : 'No campus assigned — ask your Owner or Principal for access.'}
        </p>
      )}
    </div>
  );
}
