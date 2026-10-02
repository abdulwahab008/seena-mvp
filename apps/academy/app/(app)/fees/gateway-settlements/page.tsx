import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SettlementUploadForm, UnsettledDaysForm } from './settlement-forms';

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK')}`;
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function GatewaySettlementsPage() {
  const supabase = await supabaseServer();
  const [importsRes, exceptionsRes, unsettledRes, policyRes, commissionRes] = await Promise.all([
    supabase.from('gateway_settlement_import').select('id, gateway, file_name, row_count, matched_count, exception_count, status, settlement_date, created_at').order('created_at', { ascending: false }).limit(20),
    supabase.from('gateway_settlement_line').select('id, line_no, gateway_txn_id, gross_paisa, status, error_text, raw_line, import_id').in('status', ['unmatched', 'exception', 'parse_error']).order('created_at', { ascending: false }).limit(50),
    supabase.from('v_unsettled_online_payments').select('payment_id, enrolment_id, gateway_txn_id, amount_paisa, value_date, age_days').order('age_days', { ascending: false }).limit(100),
    supabase.from('gateway_settlement_policy').select('unsettled_after_days').maybeSingle(),
    supabase.from('gateway_commission').select('amount_paisa'),
  ]);
  const unsettled = unsettledRes.data ?? [];
  const enrolIds = [...new Set(unsettled.map((u) => u.enrolment_id).filter((v): v is string => Boolean(v)))];
  const { data: enrols } = enrolIds.length
    ? await supabase.from('enrolment').select('id, student:student_id(name_en, gr_number)').in('id', enrolIds)
    : { data: [] };
  const names = new Map((enrols ?? []).map((e) => [e.id, one(e.student)]));
  const totalCommission = (commissionRes.data ?? []).reduce((sum, c) => sum + Number(c.amount_paisa), 0);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Gateway settlements</h1>
        <p className="text-sm text-muted-foreground">
          FR-K23 — the student is credited the full amount paid; the gateway&apos;s commission is recorded as a school expense and never reduces what a family has paid. Commission recorded so far: {pkr(totalCommission)}.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Import a settlement report</CardTitle>
        </CardHeader>
        <CardContent>
          <SettlementUploadForm />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Unsettled online payments ({unsettled.length})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="unsettled-list">
          <UnsettledDaysForm days={policyRes.data?.unsettled_after_days ?? 3} />
          {unsettled.length === 0 && <p className="text-muted-foreground">Every online payment older than the threshold has been settled.</p>}
          {unsettled.map((u) => {
            const student = u.enrolment_id ? names.get(u.enrolment_id) : null;
            return (
              <div key={u.payment_id ?? u.gateway_txn_id} className="flex justify-between border-b py-1" data-testid="unsettled-row">
                <span>
                  {student?.name_en ?? 'Student'} · GR {student?.gr_number ?? '—'} · {u.gateway_txn_id} · {pkr(Number(u.amount_paisa))}
                </span>
                <Badge variant="destructive">{u.age_days} days</Badge>
              </div>
            );
          })}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Exceptions ({(exceptionsRes.data ?? []).length})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm" data-testid="settlement-exceptions">
          {(exceptionsRes.data ?? []).length === 0 && <p className="text-muted-foreground">No exceptions.</p>}
          {(exceptionsRes.data ?? []).map((l) => (
            <div key={l.id} className="border-b py-1" data-testid="settlement-exception">
              <span className="font-medium">{l.gateway_txn_id ?? `row ${l.line_no}`}</span>
              {l.gross_paisa !== null && ` · ${pkr(Number(l.gross_paisa))}`} — {l.error_text ?? l.status}
            </div>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Imports</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm" data-testid="settlement-imports">
          {(importsRes.data ?? []).length === 0 && <p className="text-muted-foreground">No settlement files imported yet.</p>}
          {(importsRes.data ?? []).map((i) => (
            <div key={i.id} className="flex justify-between border-b py-1" data-testid="settlement-import-row">
              <span>
                {i.gateway} · {i.file_name ?? 'settlement'} — {i.matched_count} matched, {i.exception_count} exceptions of {i.row_count}
              </span>
              <span className="text-muted-foreground">{i.status}</span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
