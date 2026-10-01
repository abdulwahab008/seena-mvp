import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ActionButton, SpecForm } from '@/components/spec-form';
import { currentRole, loose, pickCampus, pkr, todayPk } from '@/lib/transport/rpc';
import { postCharges, receiveDeposit, refundDeposit, saveTariff } from './actions';

export const dynamic = 'force-dynamic';

type Tariff = { id: string; room_type: string; monthly_amount_paisa: number; mess_rate_per_day_paisa: number; security_deposit_paisa: number; effective_from: string };
type Dep = {
  id: string; amount_paisa: number; charged_on: string; received_on: string | null; refunded_on: string | null; refund_voucher_no: string | null;
  student: { name_en: string; gr_number: string } | { name_en: string; gr_number: string }[] | null;
};
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function HostelFeesPage({ searchParams }: { searchParams: Promise<{ campus_id?: string; gr?: string; month?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const canEdit = ['owner', 'super_admin', 'principal', 'accountant'].includes(role);
  const today = todayPk();
  const month = /^\d{4}-\d{2}-\d{2}$/.test(sp.month ?? '') ? (sp.month as string) : today;

  const [{ data: tariffs }, { data: deposits }] = await Promise.all([
    supabase.from('hostel_tariff').select('id, room_type, monthly_amount_paisa, mess_rate_per_day_paisa, security_deposit_paisa, effective_from').eq('campus_id', campus.id).order('room_type').order('effective_from', { ascending: false }),
    supabase.from('hostel_security_deposit').select('id, amount_paisa, charged_on, received_on, refunded_on, refund_voucher_no, student:student_id(name_en, gr_number)').eq('campus_id', campus.id).order('charged_on', { ascending: false }),
  ]);

  let explain: Record<string, unknown> | null = null;
  let explainError: string | null = null;
  if (sp.gr) {
    const { data: s } = await supabase.from('student').select('id, name_en').eq('gr_number', sp.gr).maybeSingle();
    if (!s) explainError = 'No student has that GR number.';
    else {
      const { data, error } = await supabase.rpc('hostel_monthly_amount', { p_student_id: (s as { id: string }).id, p_month: month });
      if (error) explainError = 'You cannot view this breakdown.';
      else explain = { name: (s as { name_en: string }).name_en, ...(data as Record<string, unknown>) };
    }
  }
  const n = (k: string) => Number((explain as Record<string, unknown>)?.[k] ?? 0);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Hostel and mess fees</h1>
        <p className="text-sm text-muted-foreground">
          FR-Q06 — charges come from the room tariff and the days actually housed and fed; nothing is typed per student. The refundable deposit is a liability, not income.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Tariffs</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm">
          <table className="w-full" data-testid="tariff-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Room type</th>
                <th>Monthly</th>
                <th>Mess per day</th>
                <th>Deposit</th>
                <th>From</th>
              </tr>
            </thead>
            <tbody>
              {((tariffs ?? []) as Tariff[]).map((t) => (
                <tr key={t.id} className="border-t" data-testid="tariff-row">
                  <td className="py-1">{t.room_type}</td>
                  <td>{pkr(t.monthly_amount_paisa)}</td>
                  <td>{pkr(t.mess_rate_per_day_paisa)}</td>
                  <td>{pkr(t.security_deposit_paisa)}</td>
                  <td>{t.effective_from}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {canEdit && (
            <SpecForm
              testId="tariff-form"
              submitLabel="Save tariff"
              action={saveTariff}
              columns={3}
              fields={[
                { name: 'campusId', label: 'Campus', type: 'hidden', defaultValue: campus.id },
                { name: 'roomType', label: 'Room type', type: 'select', required: true, defaultValue: 'quad', options: ['single', 'double', 'triple', 'quad', 'dorm'].map((r) => ({ value: r, label: r })) },
                { name: 'monthly', label: 'Monthly room fee (PKR)', type: 'number', required: true, min: '1' },
                { name: 'messRate', label: 'Mess rate per day (PKR)', type: 'number', required: true, defaultValue: '0', min: '0' },
                { name: 'deposit', label: 'Security deposit (PKR)', type: 'number', required: true, defaultValue: '0', min: '0' },
                { name: 'effectiveFrom', label: 'Effective from', type: 'date', required: true },
              ]}
            />
          )}
        </CardContent>
      </Card>

      {canEdit && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Post a month</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <p className="text-muted-foreground">Runs automatically on the 1st, ahead of challan generation, and corrects last month. Running it again only posts differences.</p>
            <SpecForm testId="post-hostel-form" submitLabel="Post charges" action={postCharges} columns={2} fields={[{ name: 'month', label: 'Any day in the month', type: 'date', required: true, defaultValue: today }]} />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Explain a boarder&apos;s month</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          <form method="get" className="flex flex-wrap items-end gap-3">
            <label className="space-y-1">
              <span className="block text-muted-foreground">GR number</span>
              <input name="gr" defaultValue={sp.gr ?? ''} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <label className="space-y-1">
              <span className="block text-muted-foreground">Month</span>
              <input type="date" name="month" defaultValue={month} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <button type="submit" className="h-9 rounded-md border px-3" data-testid="explain-submit">
              Show
            </button>
          </form>
          {explainError && <p role="alert" className="text-destructive">{explainError}</p>}
          {explain && (
            <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1" data-testid="explain">
              <dt className="text-muted-foreground">Student</dt>
              <dd>{String(explain.name)}</dd>
              <dt className="text-muted-foreground">Room fee</dt>
              <dd data-testid="explain-room">{pkr(n('room_paisa'))} for {n('days_in_month')} days in month, less concession {pkr(n('room_concession_paisa'))} = {pkr(n('room_net_paisa'))}</dd>
              <dt className="text-muted-foreground">Mess</dt>
              <dd data-testid="explain-mess">{n('mess_days')} billable days x {pkr(n('mess_rate_paisa'))} = {pkr(n('mess_paisa'))}, less concession {pkr(n('mess_concession_paisa'))} = {pkr(n('mess_net_paisa'))}</dd>
            </dl>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Security deposits (held as a liability)</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          {((deposits ?? []) as Dep[]).map((d) => (
            <div key={d.id} className="flex flex-wrap items-center justify-between gap-3 border-b pb-2" data-testid="deposit-row">
              <span>
                {one(d.student)?.name_en} ({one(d.student)?.gr_number}) · {pkr(d.amount_paisa)} charged {d.charged_on}
              </span>
              <span className="flex flex-wrap items-center gap-2">
                {d.refunded_on ? <Badge variant="outline">refunded {d.refunded_on} · {d.refund_voucher_no}</Badge> : d.received_on ? <Badge variant="success">held since {d.received_on}</Badge> : <Badge variant="warning">not yet received</Badge>}
                {canEdit && !d.received_on && <ActionButton label="Mark received" action={() => receiveDeposit(d.id)} />}
                {canEdit && d.received_on && !d.refunded_on && (
                  <SpecForm
                    testId={`refund-form-${one(d.student)?.gr_number}`}
                    submitLabel="Refund"
                    action={refundDeposit}
                    columns={2}
                    fields={[
                      { name: 'depositId', label: 'Deposit', type: 'hidden', defaultValue: d.id },
                      { name: 'voucherNo', label: 'Refund voucher no.', required: true },
                    ]}
                  />
                )}
              </span>
            </div>
          ))}
          {(deposits ?? []).length === 0 && <p className="text-muted-foreground">No deposits yet.</p>}
        </CardContent>
      </Card>
    </div>
  );
}
