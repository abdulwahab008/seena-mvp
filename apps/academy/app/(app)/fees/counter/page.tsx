import { supabaseServer } from '@/lib/supabase/server';
import { CounterView } from './counter-view';
import { ManagePanel, ShiftPanel, type CounterOption, type OpenSession, type RecentSession } from './shift-panel';

export default async function CashCounterPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role;
  // Front-desk staff run a shift for admission-fee cash; only fee collectors take challan payments here.
  const canCollect = role === 'super_admin' || role === 'owner' || role === 'accountant';
  const runsShift = canCollect || role === 'admissions_officer' || role === 'receptionist';
  const canManage = role === 'super_admin' || role === 'owner' || role === 'principal';

  let counters: CounterOption[] = [];
  let openSession: OpenSession | null = null;
  if (runsShift) {
    const { data: counterRows } = await supabase
      .from('cash_counter')
      .select('id, name, campus_id, variance_threshold_paisa')
      .eq('is_active', true)
      .order('name');
    counters = (counterRows ?? []).map((c) => ({ id: c.id, name: c.name, campusId: c.campus_id, thresholdPaisa: c.variance_threshold_paisa }));

    const { data: mine } = await supabase
      .from('cash_counter_session')
      .select('id, opened_at, opening_float_paisa, countersigned_by, counter:cash_counter(name)')
      .eq('opened_by', user!.id)
      .eq('status', 'open')
      .maybeSingle();
    if (mine) {
      const { data: totals } = await supabase.rpc('counter_session_totals', { p_session_id: mine.id });
      const t = totals as { receipt_count: number; cash_total_paisa: number } | null;
      openSession = {
        id: mine.id,
        counterName: mine.counter?.name ?? 'Counter',
        openedAt: mine.opened_at,
        openingFloatPaisa: mine.opening_float_paisa,
        receiptCount: t?.receipt_count ?? 0,
        cashTotalPaisa: t?.cash_total_paisa ?? 0,
        countersigned: mine.countersigned_by !== null,
      };
    }
  }

  let campuses: { id: string; name: string }[] = [];
  let recent: RecentSession[] = [];
  if (canManage) {
    const { data: campusRows } = await supabase.from('campus').select('id, name').order('name');
    campuses = campusRows ?? [];
    const { data: sessionRows } = await supabase
      .from('cash_counter_session')
      .select(
        'id, status, opened_by, opening_float_paisa, system_total_paisa, declared_total_paisa, variance_paisa, countersigned_by, counter:cash_counter(name), opener:app_user!cash_counter_session_opened_by_fkey(full_name)',
      )
      .order('opened_at', { ascending: false })
      .limit(15);
    recent = (sessionRows ?? []).map((s) => ({
      id: s.id,
      counterName: s.counter?.name ?? 'Counter',
      openedByName: s.opener?.full_name ?? 'Unknown',
      status: s.status,
      openingFloatPaisa: s.opening_float_paisa,
      systemTotalPaisa: s.system_total_paisa,
      declaredTotalPaisa: s.declared_total_paisa,
      variancePaisa: s.variance_paisa,
      countersigned: s.countersigned_by !== null,
      isOwnSession: s.opened_by === user!.id,
    }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Cash counter</h1>
        <p className="text-sm text-muted-foreground">
          Open a shift, take cash against challans and admission fees, then close the shift against a physical count.
        </p>
      </div>
      {runsShift && <ShiftPanel counters={counters} openSession={openSession} />}
      {canCollect ? (
        <CounterView />
      ) : (
        !canManage &&
        !runsShift && <p className="text-sm text-muted-foreground">Only finance and front-desk staff use the cash counter.</p>
      )}
      {canManage && <ManagePanel campuses={campuses} recent={recent} />}
    </div>
  );
}
