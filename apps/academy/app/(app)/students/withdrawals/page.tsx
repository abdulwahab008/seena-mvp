import { supabaseServer } from '@/lib/supabase/server';
import { formatDatePk, todayPk } from '@/lib/dates';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const STATUS: Record<string, string> = { left: 'Left', transferred: 'Transferred out' };

export default async function WithdrawalRegisterPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const sp = await searchParams;
  const to = sp.to && DATE.test(sp.to) ? sp.to : todayPk();
  const from = sp.from && DATE.test(sp.from) ? sp.from : `${Number(to.slice(5, 7)) >= 8 ? to.slice(0, 4) : Number(to.slice(0, 4)) - 1}-08-01`;
  const supabase = await supabaseServer();
  const [{ data: withdrawn }, { count: admitted }, { count: active }] = await Promise.all([
    supabase
      .from('enrolment')
      .select('id, status, joined_on, left_on, tc_issued_at, student(name_en, gr_number), class_level(name_en), class_section(name)')
      .in('status', ['left', 'transferred'])
      .gte('left_on', from)
      .lte('left_on', to)
      .is('deleted_at', null)
      .order('left_on', { ascending: false }),
    supabase.from('enrolment').select('id', { count: 'exact', head: true }).gte('joined_on', from).lte('joined_on', to).is('deleted_at', null),
    supabase.from('enrolment').select('id', { count: 'exact', head: true }).eq('status', 'active').is('deleted_at', null),
  ]);
  const left = (withdrawn ?? []).length;
  const retention = (active ?? 0) + left > 0 ? ((active ?? 0) * 100) / ((active ?? 0) + left) : 100;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Withdrawal register</h1>
        <p className="text-sm text-muted-foreground">Students who left or transferred out between two dates, with admissions over the same period and how many students the school kept.</p>
      </div>
      <form method="get" className="flex flex-wrap items-end gap-2 text-sm">
        {[
          { name: 'from', label: 'From', value: from },
          { name: 'to', label: 'To', value: to },
        ].map((f) => (
          <label key={f.name} className="space-y-1">
            <span className="block text-muted-foreground">{f.label}</span>
            <input name={f.name} type="date" defaultValue={f.value} className="h-9 rounded-md border bg-background px-2" />
          </label>
        ))}
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>
      <div className="grid gap-4 sm:grid-cols-3">
        {[
          { label: 'Admissions', value: String(admitted ?? 0), id: 'admitted' },
          { label: 'Withdrawals', value: String(left), id: 'withdrawn' },
          { label: 'Retention', value: `${retention.toFixed(1)}%`, id: 'retention' },
        ].map((k) => (
          <Card key={k.id}>
            <CardHeader className="pb-1">
              <CardTitle className="text-sm font-normal text-muted-foreground">{k.label}</CardTitle>
            </CardHeader>
            <CardContent className="text-2xl font-semibold" data-testid={`kpi-${k.id}`}>
              {k.value}
            </CardContent>
          </Card>
        ))}
      </div>
      {left === 0 ? (
        <p className="text-sm text-muted-foreground">No withdrawals in this period.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Left on</TableHead>
              <TableHead>Student</TableHead>
              <TableHead>Class</TableHead>
              <TableHead>Joined</TableHead>
              <TableHead>How</TableHead>
              <TableHead>TC</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(withdrawn ?? []).map((e) => {
              const s = one(e.student);
              return (
                <TableRow key={e.id} data-testid="withdrawal-row">
                  <TableCell>{e.left_on ? formatDatePk(e.left_on) : ''}</TableCell>
                  <TableCell>
                    {s?.name_en} <span className="text-xs text-muted-foreground">{s?.gr_number}</span>
                  </TableCell>
                  <TableCell>
                    {one(e.class_level)?.name_en} {one(e.class_section)?.name}
                  </TableCell>
                  <TableCell>{formatDatePk(e.joined_on)}</TableCell>
                  <TableCell>{STATUS[e.status] ?? e.status}</TableCell>
                  <TableCell>{e.tc_issued_at ? formatDatePk(e.tc_issued_at.slice(0, 10)) : 'Not issued'}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
