import { supabaseServer } from '@/lib/supabase/server';
import { LateFeeRuleView, type RuleRow, type ChallanOption } from './late-fee-rule-view';

export default async function LateFeeRulesPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: sessions }] = await Promise.all([
    supabase.from('campus').select('id').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id').eq('is_current', true).order('starts_on', { ascending: false }),
  ]);

  const campus = campuses?.[0];
  const session = sessions?.[0];

  let rules: RuleRow[] = [];
  let challans: ChallanOption[] = [];
  let canConfigure = false;

  if (campus && session) {
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
    canConfigure = appUser?.app_role === 'super_admin' || appUser?.app_role === 'owner';

    const [{ data: ruleRows }, { data: challanRows }] = await Promise.all([
      supabase
        .from('late_fee_rule')
        .select('id, basis, grace_days, amount_paisa, percentage, cap_paisa, effective_from')
        .eq('campus_id', campus.id)
        .eq('session_id', session.id)
        .order('effective_from', { ascending: false }),
      supabase
        .from('fee_challan')
        .select('id, challan_no')
        .eq('campus_id', campus.id)
        .eq('session_id', session.id)
        .order('created_at', { ascending: false })
        .limit(50),
    ]);

    rules = (ruleRows ?? []).map((r) => ({
      id: r.id,
      basis: r.basis,
      graceDays: r.grace_days,
      amountPaisa: r.amount_paisa,
      percentage: r.percentage,
      capPaisa: r.cap_paisa,
      effectiveFrom: r.effective_from,
    }));
    challans = (challanRows ?? []).map((c) => ({ id: c.id, challanNo: c.challan_no }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Late fee rules</h1>
        <p className="text-sm text-muted-foreground">
          FR-K12 — the currently active rule is the most recently created one whose effective date has arrived.
        </p>
      </div>
      {campus && session ? (
        <LateFeeRuleView campusId={campus.id} sessionId={session.id} rules={rules} challans={challans} canConfigure={canConfigure} />
      ) : (
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      )}
    </div>
  );
}
