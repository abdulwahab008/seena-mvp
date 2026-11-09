import { supabaseServer } from '@/lib/supabase/server';
import { formatPkrCompact } from '@/lib/format-money';
import { formatDatePk, todayPk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { CommitmentStatusButtons } from './commitment-forms';

export const dynamic = 'force-dynamic';

type Who = { student: { name_en: string; gr_number: string } | null } | null;

export default async function FeeCommitmentsPage() {
  const supabase = await supabaseServer();
  const today = todayPk();
  const [{ data: open }, { data: debts }] = await Promise.all([
    supabase
      .from('fee_commitment')
      .select(
        'id, promised_date, amount_paisa, note, enrolment:enrolment_id(student:student_id(name_en, gr_number))',
      )
      .eq('status', 'open')
      .order('promised_date')
      .limit(300),
    supabase
      .from('fee_bad_debt')
      .select(
        'id, amount_paisa, reason, written_off_on, enrolment:enrolment_id(student:student_id(name_en, gr_number))',
      )
      .order('written_off_on', { ascending: false })
      .limit(200),
  ]);

  const rows = open ?? [];
  const overdue = rows.filter((r) => r.promised_date < today);
  const dueToday = rows.filter((r) => r.promised_date === today);
  const sum = (xs: { amount_paisa: number }[]) =>
    xs.reduce((s, r) => s + Number(r.amount_paisa), 0);

  const tiles = [
    { label: 'Due today', count: dueToday.length, paisa: sum(dueToday) },
    { label: 'Overdue promises', count: overdue.length, paisa: sum(overdue) },
    { label: 'All open promises', count: rows.length, paisa: sum(rows) },
    { label: 'Written off as bad debt', count: (debts ?? []).length, paisa: sum(debts ?? []) },
  ];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Fee commitments and bad debts</h1>
        <p className="text-sm text-muted-foreground">
          Promises to pay recorded at the counter or from the defaulter list, and fees written off
          as bad debt.
        </p>
      </div>

      <div className="grid gap-3 sm:grid-cols-4">
        {tiles.map((t) => (
          <Card key={t.label}>
            <CardHeader className="p-3">
              <CardDescription>{t.label}</CardDescription>
              <CardTitle className="text-lg">{formatPkrCompact(t.paisa)}</CardTitle>
              <p className="text-xs text-muted-foreground">{t.count} students</p>
            </CardHeader>
          </Card>
        ))}
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Open promises</CardTitle>
          <CardDescription>Record a new promise from the Defaulters list.</CardDescription>
        </CardHeader>
        <CardContent>
          {rows.length === 0 ? (
            <EmptyState
              title="No open promises"
              description="Promises recorded from the defaulter list appear here."
            />
          ) : (
            <div className="overflow-x-auto rounded-md border">
              <table className="w-full min-w-[640px] text-sm" data-testid="commitment-table">
                <thead className="bg-muted/50 text-left">
                  <tr>
                    <th className="p-2">Date</th>
                    <th className="p-2">GR</th>
                    <th className="p-2">Student</th>
                    <th className="p-2">Amount</th>
                    <th className="p-2">Note</th>
                    <th className="p-2" />
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => {
                    const s = (r.enrolment as Who)?.student;
                    return (
                      <tr key={r.id} className="border-t">
                        <td className="p-2">
                          {formatDatePk(r.promised_date)}{' '}
                          {r.promised_date < today ? (
                            <Badge variant="destructive">overdue</Badge>
                          ) : r.promised_date === today ? (
                            <Badge variant="warning">today</Badge>
                          ) : null}
                        </td>
                        <td className="p-2">{s?.gr_number ?? '—'}</td>
                        <td className="p-2">{s?.name_en ?? '—'}</td>
                        <td className="p-2">{formatPkrCompact(Number(r.amount_paisa))}</td>
                        <td className="p-2 text-muted-foreground">{r.note ?? ''}</td>
                        <td className="p-2">
                          <CommitmentStatusButtons id={r.id} />
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Bad debts</CardTitle>
          <CardDescription>
            Owner and principal can write off a defaulter&apos;s dues from the Defaulters list.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {(debts ?? []).length === 0 ? (
            <EmptyState
              title="Nothing written off"
              description="Fees written off as bad debt appear here."
            />
          ) : (
            <div className="overflow-x-auto rounded-md border">
              <table className="w-full min-w-[560px] text-sm">
                <thead className="bg-muted/50 text-left">
                  <tr>
                    <th className="p-2">Date</th>
                    <th className="p-2">GR</th>
                    <th className="p-2">Student</th>
                    <th className="p-2">Amount</th>
                    <th className="p-2">Reason</th>
                  </tr>
                </thead>
                <tbody>
                  {(debts ?? []).map((d) => {
                    const s = (d.enrolment as Who)?.student;
                    return (
                      <tr key={d.id} className="border-t">
                        <td className="p-2">{formatDatePk(d.written_off_on)}</td>
                        <td className="p-2">{s?.gr_number ?? '—'}</td>
                        <td className="p-2">{s?.name_en ?? '—'}</td>
                        <td className="p-2">{formatPkrCompact(Number(d.amount_paisa))}</td>
                        <td className="p-2 text-muted-foreground">{d.reason}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
