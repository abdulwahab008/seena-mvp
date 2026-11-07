import { supabaseServer } from '@/lib/supabase/server';
import { formatPkr } from '@/lib/challan/html';
import { todayPk } from '@/lib/dates';
import { pickActiveCampus } from '@/lib/campus-context';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { SendFeeSlips } from './send-fee-slips';

export const dynamic = 'force-dynamic';

const MONTH = new Intl.DateTimeFormat('en-PK', { month: 'short', year: 'numeric', timeZone: 'UTC' });

export default async function FeeAnalyticsPage() {
  const supabase = await supabaseServer();
  const today = todayPk();
  const yearAgo = `${Number(today.slice(0, 4)) - 1}${today.slice(4, 8)}01`;
  const [{ data: months }, { data: ageing }, { data: campuses }] = await Promise.all([
    supabase.rpc('fee_collection_by_month', { p_from: yearAgo, p_to: today }),
    supabase.rpc('fee_outstanding_ageing', { p_as_of: today }),
    supabase.from('campus').select('id, name').eq('status', 'active').order('code'),
  ]);
  const campus = await pickActiveCampus(campuses);
  const billed = (months ?? []).reduce((s, m) => s + m.billed_paisa, 0);
  const collected = (months ?? []).reduce((s, m) => s + m.collected_paisa, 0);
  const overdue = (ageing ?? []).reduce((s, a) => s + a.outstanding_paisa, 0);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Fee analytics</h1>
        <p className="text-sm text-muted-foreground">Billed against collected over the last twelve months, and what is overdue by how long.</p>
      </div>
      <div className="grid gap-4 sm:grid-cols-3">
        {[
          { label: 'Billed (12 months)', value: formatPkr(billed), id: 'billed' },
          { label: 'Collected (12 months)', value: formatPkr(collected), id: 'collected' },
          { label: 'Overdue now', value: formatPkr(overdue), id: 'overdue' },
        ].map((k) => (
          <Card key={k.id}>
            <CardHeader className="pb-1">
              <CardTitle className="text-sm font-normal text-muted-foreground">{k.label}</CardTitle>
            </CardHeader>
            <CardContent className="text-2xl font-semibold" data-testid={`fee-kpi-${k.id}`}>
              {k.value}
            </CardContent>
          </Card>
        ))}
      </div>
      <div className="grid gap-6 lg:grid-cols-2">
        <section className="space-y-2">
          <h2 className="font-medium">By month</h2>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Month</TableHead>
                <TableHead className="text-right">Billed</TableHead>
                <TableHead className="text-right">Collected</TableHead>
                <TableHead className="text-right">Collected %</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(months ?? []).map((m) => (
                <TableRow key={m.month}>
                  <TableCell>{MONTH.format(new Date(`${m.month}T00:00:00Z`))}</TableCell>
                  <TableCell className="text-right">{formatPkr(m.billed_paisa)}</TableCell>
                  <TableCell className="text-right">{formatPkr(m.collected_paisa)}</TableCell>
                  <TableCell className="text-right">{m.billed_paisa > 0 ? `${((m.collected_paisa * 100) / m.billed_paisa).toFixed(0)}%` : '–'}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </section>
        <section className="space-y-2">
          <h2 className="font-medium">Overdue by age</h2>
          {(ageing ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">Nothing is overdue.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Past due</TableHead>
                  <TableHead className="text-right">Challans</TableHead>
                  <TableHead className="text-right">Outstanding</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(ageing ?? []).map((a) => (
                  <TableRow key={a.bucket} data-testid="ageing-row">
                    <TableCell>{a.bucket}</TableCell>
                    <TableCell className="text-right">{a.challans}</TableCell>
                    <TableCell className="text-right">{formatPkr(a.outstanding_paisa)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          {campus && <SendFeeSlips campusId={campus.id} defaultMonth={today.slice(0, 7)} />}
        </section>
      </div>
    </div>
  );
}
