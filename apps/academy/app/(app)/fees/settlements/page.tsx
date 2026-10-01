import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { DecideButtons, DisburseForm, ProposeForm } from './settlement-forms';

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK')}`;

export default async function SettlementsPage() {
  const supabase = await supabaseServer();
  const { data: rows } = await supabase
    .from('fee_settlement')
    .select('id, leaving_date, basis, credit_adjustment_paisa, net_refund_paisa, remaining_dues_paisa, requires_owner, status, instrument_ref, created_at, enrolment:enrolment_id(student:student_id(name_en, gr_number))')
    .order('created_at', { ascending: false })
    .limit(50);
  const { data: approvals } = await supabase.from('fee_settlement_approval').select('settlement_id, role, decision');

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Withdrawal settlements</h1>
        <p className="text-sm text-muted-foreground">
          FR-K27 — unearned fees are credited back pro-rata, what the family owes is netted, and only the remainder is refunded. The Principal approves; above the owner threshold the Owner approves too; only then can the refund be disbursed.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Propose a settlement</CardTitle>
        </CardHeader>
        <CardContent>
          <ProposeForm />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Settlements</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3" data-testid="settlement-list">
          {(rows ?? []).length === 0 && <p className="text-sm text-muted-foreground">None yet.</p>}
          {(rows ?? []).map((s) => {
            const enrol = Array.isArray(s.enrolment) ? s.enrolment[0] : s.enrolment;
            const student = enrol ? (Array.isArray(enrol.student) ? enrol.student[0] : enrol.student) : null;
            const done = (approvals ?? []).filter((a) => a.settlement_id === s.id && a.decision === 'approved').map((a) => a.role);
            return (
              <div key={s.id} className="space-y-2 border-b pb-3 text-sm" data-testid="settlement-row">
                <div className="flex items-center justify-between">
                  <span className="font-medium">
                    {student?.name_en ?? 'Student'} · GR {student?.gr_number ?? '—'} · leaving {s.leaving_date} ({s.basis.replace('_', ' ')})
                  </span>
                  <Badge variant={s.status === 'disbursed' ? 'success' : s.status === 'rejected' ? 'destructive' : 'outline'}>{s.status}</Badge>
                </div>
                <p className="text-muted-foreground">
                  Credit back {pkr(Number(s.credit_adjustment_paisa))} · refund {pkr(Number(s.net_refund_paisa))}
                  {Number(s.remaining_dues_paisa) > 0 ? ` · still owed ${pkr(Number(s.remaining_dues_paisa))}` : ''} · approvals: {done.join(', ') || 'none'}
                  {s.requires_owner ? ' (owner required)' : ''}
                  {s.instrument_ref ? ` · ref ${s.instrument_ref}` : ''}
                </p>
                {s.status === 'pending' && <DecideButtons settlementId={s.id} />}
                {s.status === 'approved' && <DisburseForm settlementId={s.id} />}
              </div>
            );
          })}
        </CardContent>
      </Card>
    </div>
  );
}
