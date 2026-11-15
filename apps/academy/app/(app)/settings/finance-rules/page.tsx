import { supabaseServer } from '@/lib/supabase/server';
import { pkr } from '@/lib/rpc-action';
import { ActionForm } from '@/components/action-form';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { setExpenseApprovalLimits, setPettyCashLimits, setReturnWindow, setSettlementThreshold, setTcNoDues } from './actions';

export const dynamic = 'force-dynamic';

const rupees = (paisa: number | null | undefined) => (paisa == null ? '' : String(Number(paisa) / 100));

export default async function FinanceRulesPage() {
  const supabase = await supabaseServer();
  const [{ data: campuses }, { data: bands }, { data: petty }, { data: settlement }, { data: noDues }, { data: inv }] = await Promise.all([
    supabase.from('campus').select('id, name').eq('status', 'active').order('name'),
    supabase.from('approval_threshold').select('campus_id, min_amount_paisa, max_amount_paisa, required_role').order('min_amount_paisa'),
    supabase.from('petty_cash_account').select('id, campus_id, float_paisa, txn_cap_paisa'),
    supabase.from('fee_settlement_policy').select('owner_threshold_paisa').maybeSingle(),
    supabase.from('no_dues_policy').select('tc_requires_clearance').maybeSingle(),
    supabase.from('inv_setting').select('return_window_days').maybeSingle(),
  ]);
  const campusName = new Map((campuses ?? []).map((c) => [c.id, c.name]));
  const campusOptions = (campuses ?? []).map((c) => ({ value: c.id, label: c.name }));
  const threshold = settlement?.owner_threshold_paisa ?? 2500000;

  return (
    <div className="space-y-6">
      <PageHeader title="Finance rules" description="Who approves spending, petty cash limits, and the rules for refunds, transfer certificates and shop returns." />

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Who approves an expense</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-6 md:grid-cols-2">
          <ul className="space-y-2 text-sm" data-testid="approval-bands">
            {(campuses ?? []).map((c) => (
              <li key={c.id}>
                <p className="font-medium">{c.name}</p>
                {(bands ?? [])
                  .filter((b) => b.campus_id === c.id)
                  .map((b) => (
                    <p key={b.min_amount_paisa} className="text-muted-foreground">
                      {b.max_amount_paisa == null ? `Above ${pkr(b.min_amount_paisa - 1)}` : `${pkr(b.min_amount_paisa)} to ${pkr(b.max_amount_paisa)}`}:{' '}
                      {b.required_role ? `the ${b.required_role.replace('_', ' ')}` : 'no approval needed'}
                    </p>
                  ))}
              </li>
            ))}
          </ul>
          <ActionForm
            testId="approval-limits-form"
            submitLabel="Save limits"
            action={setExpenseApprovalLimits}
            fields={[
              { name: 'campusId', label: 'Campus', type: 'select', required: true, options: campusOptions },
              { name: 'selfMaxPkr', label: 'No approval needed up to (PKR)', type: 'number', required: true, defaultValue: '25000' },
              { name: 'principalMaxPkr', label: 'Principal approves up to (PKR); the owner above', type: 'number', required: true, defaultValue: '200000' },
            ]}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Petty cash</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-6 md:grid-cols-2">
          {(petty ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">No petty cash account yet. Open one under Expenses, Petty Cash.</p>
          ) : (
            <>
              <ul className="space-y-1 text-sm" data-testid="petty-cash-limits">
                {(petty ?? []).map((a) => (
                  <li key={a.id}>
                    <span className="font-medium">{campusName.get(a.campus_id) ?? 'Campus'}:</span> float {pkr(a.float_paisa)}, at most {pkr(a.txn_cap_paisa)} a payment
                  </li>
                ))}
              </ul>
              <ActionForm
                testId="petty-cash-form"
                submitLabel="Save limits"
                action={setPettyCashLimits}
                fields={[
                  { name: 'accountId', label: 'Account', type: 'select', required: true, options: (petty ?? []).map((a) => ({ value: a.id, label: campusName.get(a.campus_id) ?? 'Campus' })) },
                  { name: 'floatPkr', label: 'Float (PKR)', type: 'number', required: true },
                  { name: 'txnCapPkr', label: 'Most per payment (PKR)', type: 'number', required: true },
                ]}
              />
            </>
          )}
        </CardContent>
      </Card>

      <div className="grid gap-6 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Leaving refunds</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p data-testid="settlement-threshold">A fee settlement refunding more than {pkr(threshold)} needs the owner&apos;s approval.</p>
            <ActionForm
              testId="settlement-threshold-form"
              submitLabel="Save"
              action={setSettlementThreshold}
              fields={[{ name: 'thresholdPkr', label: 'Owner approves above (PKR)', type: 'number', required: true, defaultValue: rupees(threshold) }]}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Transfer certificates</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p data-testid="tc-rule">
              {noDues?.tc_requires_clearance ? 'A TC is issued only after no-dues clearance.' : 'A TC can be issued without no-dues clearance.'}
            </p>
            <ActionForm
              testId="tc-rule-form"
              submitLabel="Save"
              action={setTcNoDues}
              fields={[
                {
                  name: 'required',
                  label: 'Require no-dues clearance first',
                  type: 'select',
                  required: true,
                  options: [
                    { value: 'yes', label: 'Yes' },
                    { value: 'no', label: 'No' },
                  ],
                },
              ]}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Shop returns</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p data-testid="return-window">Items can be returned within {inv?.return_window_days ?? 7} days of sale.</p>
            <ActionForm
              testId="return-window-form"
              submitLabel="Save"
              action={setReturnWindow}
              fields={[{ name: 'days', label: 'Days to return an item', type: 'number', required: true, defaultValue: String(inv?.return_window_days ?? 7) }]}
            />
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
