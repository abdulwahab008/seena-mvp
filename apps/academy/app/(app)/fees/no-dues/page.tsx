import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ClearanceActions, ItemControls, RecordDepositForm, StartClearanceForm } from './forms';

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK')}`;
const DOMAIN_LABEL: Record<string, string> = { fees: 'Fees', library: 'Library', transport: 'Transport', hostel: 'Hostel', inventory: 'Inventory' };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function NoDuesPage() {
  const supabase = await supabaseServer();
  const [clearanceRes, depositRes] = await Promise.all([
    supabase
      .from('no_dues_clearance')
      .select('id, enrolment_id, status, requested_at, override_reason, items:no_dues_item(id, domain, outstanding_paisa, netted_paisa, status, note), enrolment:enrolment_id(student:student_id(name_en, gr_number))')
      .order('requested_at', { ascending: false })
      .limit(40),
    supabase.from('security_deposit').select('enrolment_id, amount_paisa, netted_paisa, status, approved_at, refund_paisa, received_on').in('status', ['held', 'refunded', 'adjusted']),
  ]);
  const deposits = new Map((depositRes.data ?? []).map((d) => [d.enrolment_id, d]));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Security deposits and no-dues clearance</h1>
        <p className="text-sm text-muted-foreground">
          FR-K28 — a deposit is held as a liability and never counted as income. Fees, library, transport, hostel and inventory are cleared by their owners; dues can be netted against the deposit; the Principal approves the refund; only the Owner can override an open clearance to release the Transfer Certificate.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Record a security deposit</CardTitle>
        </CardHeader>
        <CardContent>
          <RecordDepositForm />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Start a no-dues clearance</CardTitle>
        </CardHeader>
        <CardContent>
          <StartClearanceForm />
        </CardContent>
      </Card>

      <div className="space-y-4" data-testid="clearance-list">
        {(clearanceRes.data ?? []).length === 0 && <p className="text-sm text-muted-foreground">No clearances yet.</p>}
        {(clearanceRes.data ?? []).map((c) => {
          const student = one(one(c.enrolment)?.student ?? null);
          const dep = deposits.get(c.enrolment_id);
          const held = dep?.status === 'held';
          return (
            <Card key={c.id} data-testid="clearance-card">
              <CardHeader>
                <CardTitle className="flex items-center justify-between text-base">
                  <span>
                    {student?.name_en ?? 'Student'} · GR {student?.gr_number ?? '—'}
                  </span>
                  <Badge variant={c.status === 'cleared' ? 'success' : c.status === 'overridden' ? 'destructive' : 'outline'}>{c.status}</Badge>
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-3 text-sm">
                <p data-testid="deposit-line">
                  {dep ? `Deposit ${pkr(Number(dep.amount_paisa))} — ${dep.status}${Number(dep.netted_paisa) > 0 ? `, ${pkr(Number(dep.netted_paisa))} netted` : ''}${dep.approved_at ? ', refund approved' : ''}` : 'No deposit on record.'}
                </p>
                {c.override_reason && <p className="text-destructive">Overridden: {c.override_reason}</p>}
                {(c.items ?? []).map((i) => (
                  <div key={i.id} className="space-y-2 border-t pt-2" data-testid="no-dues-item">
                    <div className="flex items-center justify-between">
                      <span className="font-medium">{DOMAIN_LABEL[i.domain] ?? i.domain}</span>
                      <span className="flex items-center gap-2">
                        {Number(i.outstanding_paisa) > 0 && <span className="text-muted-foreground">owed {pkr(Number(i.outstanding_paisa))}{Number(i.netted_paisa) > 0 ? ` (netted ${pkr(Number(i.netted_paisa))})` : ''}</span>}
                        <Badge variant={i.status === 'pending' ? 'outline' : 'success'}>{i.status}</Badge>
                      </span>
                    </div>
                    {c.status === 'open' && i.status === 'pending' && <ItemControls itemId={i.id} domain={i.domain} hasDeposit={held && !dep?.approved_at} />}
                  </div>
                ))}
                <ClearanceActions clearanceId={c.id} enrolmentId={c.enrolment_id} status={c.status} hasDeposit={Boolean(held)} approved={Boolean(dep?.approved_at)} />
              </CardContent>
            </Card>
          );
        })}
      </div>
    </div>
  );
}
