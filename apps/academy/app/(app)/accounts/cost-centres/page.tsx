import { notFound } from 'next/navigation';
import { Building2 } from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatPkr } from '@/lib/challan/html';
import { todayPk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { EmptyState } from '@/components/ui/empty-state';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { CostCenterActiveButton, CostCenterForm } from './forms';

export const dynamic = 'force-dynamic';

const READERS = ['super_admin', 'owner', 'principal', 'accountant'];
const WRITERS = ['super_admin', 'owner', 'accountant'];
const DATE = /^\d{4}-\d{2}-\d{2}$/;

type CentreTotal = { key: string; code: string | null; name: string; income: number; expense: number; lines: { code: string; name: string; amount: number }[] };

export default async function CostCentresPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !READERS.includes(actor.role)) notFound();
  const canWrite = WRITERS.includes(actor.role);
  const sp = await searchParams;
  const to = sp.to && DATE.test(sp.to) ? sp.to : todayPk();
  const y = Number(to.slice(0, 4));
  const from = sp.from && DATE.test(sp.from) ? sp.from : `${Number(to.slice(5, 7)) >= 7 ? y : y - 1}-07-01`;

  const supabase = await supabaseServer();
  const [{ data: centres }, { data: report }] = await Promise.all([
    supabase.from('gl_cost_center').select('id, code, name, is_active').order('code'),
    supabase.rpc('cost_center_report', { p_from: from, p_to: to }),
  ]);

  const totals = new Map<string, CentreTotal>();
  for (const r of report ?? []) {
    const key = r.cost_center_id ?? 'none';
    const t = totals.get(key) ?? { key, code: r.cost_center_code, name: r.cost_center_name ?? 'Unallocated', income: 0, expense: 0, lines: [] };
    if (r.type === 'income') t.income += r.amount;
    else t.expense += r.amount;
    t.lines.push({ code: r.code, name: r.name, amount: r.type === 'income' ? r.amount : -r.amount });
    totals.set(key, t);
  }
  const rows = [...totals.values()];

  return (
    <>
      <PageHeader
        title="Cost centres"
        description="Tag voucher lines with a cost centre, such as a wing, the hostel or the transport fleet, to see what each one earns and spends."
      />
      <div className="space-y-8">
        <div className="grid gap-6 lg:grid-cols-[1fr_20rem]">
          {(centres ?? []).length === 0 ? (
            <EmptyState icon={Building2} title="No cost centres yet" description="Add one, then pick it on voucher lines." />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Code</TableHead>
                  <TableHead>Name</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {(centres ?? []).map((c) => (
                  <TableRow key={c.id} data-testid="cost-centre">
                    <TableCell className="font-mono">{c.code}</TableCell>
                    <TableCell>
                      {c.name} {!c.is_active && <Badge variant="outline">inactive</Badge>}
                    </TableCell>
                    <TableCell className="text-right">
                      {canWrite && <CostCenterActiveButton id={c.id} code={c.code} name={c.name} isActive={c.is_active} />}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          {canWrite && <CostCenterForm />}
        </div>

        <section className="space-y-3">
          <h2 className="font-medium">Income and expenses by cost centre</h2>
          <form method="get" className="flex flex-wrap items-end gap-2 text-sm">
            <label className="space-y-1">
              <span className="block text-muted-foreground">From</span>
              <input name="from" type="date" defaultValue={from} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <label className="space-y-1">
              <span className="block text-muted-foreground">To</span>
              <input name="to" type="date" defaultValue={to} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <button type="submit" className="h-9 rounded-md border px-3">
              Show
            </button>
          </form>
          {rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">No income or expenses posted in this period.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Cost centre</TableHead>
                  <TableHead className="text-right">Income</TableHead>
                  <TableHead className="text-right">Expenses</TableHead>
                  <TableHead className="text-right">Surplus</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => (
                  <TableRow key={r.key} data-testid="cost-centre-total">
                    <TableCell>
                      <details>
                        <summary className="cursor-pointer">
                          {r.code && <span className="font-mono">{r.code} · </span>}
                          {r.name}
                        </summary>
                        <ul className="mt-1 text-muted-foreground">
                          {r.lines.map((l) => (
                            <li key={l.code}>
                              {l.code} {l.name} · {formatPkr(l.amount)}
                            </li>
                          ))}
                        </ul>
                      </details>
                    </TableCell>
                    <TableCell className="text-right align-top">{formatPkr(r.income)}</TableCell>
                    <TableCell className="text-right align-top">{formatPkr(r.expense)}</TableCell>
                    <TableCell className="text-right align-top">{formatPkr(r.income - r.expense)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
              <TableFooter>
                <TableRow>
                  <TableCell className="font-medium">Total</TableCell>
                  <TableCell className="text-right font-medium">{formatPkr(rows.reduce((s, r) => s + r.income, 0))}</TableCell>
                  <TableCell className="text-right font-medium">{formatPkr(rows.reduce((s, r) => s + r.expense, 0))}</TableCell>
                  <TableCell className="text-right font-medium">{formatPkr(rows.reduce((s, r) => s + r.income - r.expense, 0))}</TableCell>
                </TableRow>
              </TableFooter>
            </Table>
          )}
        </section>
      </div>
    </>
  );
}
