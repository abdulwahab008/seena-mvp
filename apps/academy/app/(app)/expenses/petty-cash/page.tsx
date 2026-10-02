import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CreateAccountForm, CustodianForm, DecideButtons, PayForm, ReplenishForm } from './petty-forms';

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK')}`;

export default async function PettyCashPage() {
  const supabase = await supabaseServer();
  const [accountRes, campusRes, headRes, staffRes, txnRes, reconRes] = await Promise.all([
    supabase.from('petty_cash_account').select('id, campus_id, float_paisa, txn_cap_paisa, custodian_user_id, current_balance_paisa'),
    supabase.from('campus').select('id, name').eq('status', 'active').order('name'),
    supabase.from('expense_head').select('id, name_en').eq('is_active', true).order('name_en'),
    supabase.from('app_user').select('user_id, full_name, app_role').order('full_name'),
    supabase.from('petty_cash_txn').select('id, account_id, direction, amount_paisa, narrative, balance_after_paisa, created_at').order('created_at', { ascending: false }).limit(60),
    supabase.from('petty_cash_reconciliation').select('id, account_id, system_balance_paisa, counted_paisa, variance_paisa, explanation, status, requested_at').order('requested_at', { ascending: false }).limit(40),
  ]);
  const accounts = accountRes.data ?? [];
  const campuses = campusRes.data ?? [];
  const staff = (staffRes.data ?? []).map((s) => ({ id: s.user_id, label: `${s.full_name} (${s.app_role})` }));
  const heads = (headRes.data ?? []).map((h) => ({ id: h.id, label: h.name_en }));
  const staffName = new Map(staff.map((s) => [s.id, s.label]));
  const campusName = new Map(campuses.map((c) => [c.id, c.name]));
  const withoutAccount = campuses.filter((c) => !accounts.some((a) => a.campus_id === c.id));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Petty cash</h1>
        <p className="text-sm text-muted-foreground">
          FR-L12 — a fixed float per campus. Payments cannot exceed the balance or the per-payment cap; the tin is topped up only after a count the Principal signs off, and it always returns to exactly the float.
        </p>
      </div>

      {accounts.map((a) => {
        const txns = (txnRes.data ?? []).filter((t) => t.account_id === a.id).slice(0, 10);
        const recons = (reconRes.data ?? []).filter((r) => r.account_id === a.id);
        const pending = recons.find((r) => r.status === 'pending');
        return (
          <Card key={a.id} data-testid="petty-account">
            <CardHeader>
              <CardTitle className="flex items-center justify-between text-base">
                <span>{campusName.get(a.campus_id) ?? 'Campus'}</span>
                <span data-testid="petty-balance">{pkr(Number(a.current_balance_paisa))}</span>
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-4 text-sm">
              <p className="text-muted-foreground">
                Float {pkr(Number(a.float_paisa))} · cap per payment {pkr(Number(a.txn_cap_paisa))} · custodian {staffName.get(a.custodian_user_id) ?? '—'}
              </p>
              {pending ? (
                <div className="space-y-2 rounded-md border p-3" data-testid="petty-pending">
                  <p>
                    Count awaiting sign-off: system {pkr(Number(pending.system_balance_paisa))}, counted {pkr(Number(pending.counted_paisa))}, variance {pkr(Number(pending.variance_paisa))}
                    {pending.explanation ? ` — ${pending.explanation}` : ''}. The tin is frozen until this is decided.
                  </p>
                  <DecideButtons reconciliationId={pending.id} />
                </div>
              ) : (
                <>
                  <PayForm accountId={a.id} heads={heads} />
                  <ReplenishForm accountId={a.id} />
                </>
              )}
              <CustodianForm accountId={a.id} staff={staff} current={a.custodian_user_id} />
              <div className="space-y-1" data-testid="petty-txns">
                {txns.map((t) => (
                  <div key={t.id} className="flex justify-between border-b py-1">
                    <span>
                      <Badge variant={t.direction === 'in' ? 'success' : 'outline'}>{t.direction === 'in' ? 'in' : 'out'}</Badge> {t.narrative ?? ''}
                    </span>
                    <span>
                      {pkr(Number(t.amount_paisa))} → {pkr(Number(t.balance_after_paisa))}
                    </span>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        );
      })}

      {withoutAccount.length > 0 && staff.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Open a petty cash account</CardTitle>
          </CardHeader>
          <CardContent>
            <CreateAccountForm campuses={withoutAccount.map((c) => ({ id: c.id, label: c.name }))} staff={staff} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
