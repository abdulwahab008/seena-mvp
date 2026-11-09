import { notFound } from 'next/navigation';
import { PiggyBank } from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatPkr } from '@/lib/challan/html';
import { todayPk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { BudgetForm } from './forms';

export const dynamic = 'force-dynamic';

const READERS = ['super_admin', 'owner', 'principal', 'accountant'];
const WRITERS = ['super_admin', 'owner', 'accountant'];
const MONTH_NAMES = ['Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'];

function monthOf(fyStartYear: number, i: number): string {
  const year = i < 6 ? fyStartYear : fyStartYear + 1;
  return `${year}-${String(((i + 6) % 12) + 1).padStart(2, '0')}-01`;
}

type Line = { accountId: string; code: string; name: string; type: string; budget: number; actual: number };

export default async function BudgetsPage({ searchParams }: { searchParams: Promise<{ fy?: string; month?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !READERS.includes(actor.role)) notFound();
  const canWrite = WRITERS.includes(actor.role);
  const sp = await searchParams;
  const today = todayPk();
  const currentFy = Number(today.slice(5, 7)) >= 7 ? Number(today.slice(0, 4)) : Number(today.slice(0, 4)) - 1;
  const fy = sp.fy && /^\d{4}$/.test(sp.fy) ? Number(sp.fy) : currentFy;
  const monthIndex = sp.month && /^\d{1,2}$/.test(sp.month) && Number(sp.month) < 12 ? Number(sp.month) : null;
  const monthLabels = MONTH_NAMES.map((m, i) => `${m} ${i < 6 ? fy : fy + 1}`);

  const supabase = await supabaseServer();
  const [{ data: rows }, { data: accounts }] = await Promise.all([
    supabase.rpc('budget_vs_actual', { p_fy_start_year: fy }),
    supabase.from('gl_account').select('id, code, name, type').eq('is_active', true).in('type', ['income', 'expense']).order('code'),
  ]);

  const fyMonths = Array.from({ length: 12 }, (_, k) => monthOf(fy, k));
  const existing: Record<string, string[]> = {};
  const lines = new Map<string, Line>();
  for (const r of rows ?? []) {
    const i = fyMonths.indexOf(r.month);
    if (r.budget > 0) {
      const amounts = (existing[r.account_id] ??= Array.from({ length: 12 }, () => ''));
      amounts[i] = String(r.budget / 100);
    }
    if (monthIndex !== null && i !== monthIndex) continue;
    const l = lines.get(r.account_id) ?? { accountId: r.account_id, code: r.code, name: r.name, type: r.type, budget: 0, actual: 0 };
    l.budget += r.budget;
    l.actual += r.actual;
    lines.set(r.account_id, l);
  }
  const income = [...lines.values()].filter((l) => l.type === 'income');
  const expense = [...lines.values()].filter((l) => l.type === 'expense');
  const sections = [
    { type: 'income', title: 'Income', lines: income },
    { type: 'expense', title: 'Expenses', lines: expense },
  ];

  return (
    <>
      <PageHeader
        title="Budget vs actual"
        description="Monthly budgets for income and expense accounts, set against what has been posted to the ledger. Financial years run July to June."
      />
      <div className="space-y-6">
        <form method="get" className="flex flex-wrap items-end gap-2 text-sm">
          <label className="space-y-1">
            <span className="block text-muted-foreground">Financial year</span>
            <select name="fy" defaultValue={String(fy)} className="h-9 rounded-md border bg-background px-2">
              {[currentFy - 2, currentFy - 1, currentFy, currentFy + 1].map((y) => (
                <option key={y} value={y}>
                  {y}-{String(y + 1).slice(2)}
                </option>
              ))}
            </select>
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Period</span>
            <select name="month" defaultValue={monthIndex === null ? '' : String(monthIndex)} className="h-9 rounded-md border bg-background px-2">
              <option value="">Whole year</option>
              {monthLabels.map((m, i) => (
                <option key={m} value={i}>
                  {m}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" className="h-9 rounded-md border px-3">
            Show
          </button>
        </form>

        {lines.size === 0 ? (
          <EmptyState icon={PiggyBank} title="No budgets or postings for this period" description={canWrite ? 'Set a budget below to compare it with the ledger.' : undefined} />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Code</TableHead>
                <TableHead>Account</TableHead>
                <TableHead className="text-right">Budget</TableHead>
                <TableHead className="text-right">Actual</TableHead>
                <TableHead className="text-right">Variance</TableHead>
                <TableHead className="text-right">Used</TableHead>
              </TableRow>
            </TableHeader>
            {sections.map((s) => (
              <TableBody key={s.type}>
                <TableRow>
                  <TableCell colSpan={6} className="bg-muted/50 font-medium">
                    {s.title}
                  </TableCell>
                </TableRow>
                {s.lines.map((l) => {
                  // Favourable when income beats budget or spending stays under it.
                  const variance = s.type === 'income' ? l.actual - l.budget : l.budget - l.actual;
                  return (
                    <TableRow key={l.accountId} data-testid="budget-row">
                      <TableCell className="font-mono">{l.code}</TableCell>
                      <TableCell>{l.name}</TableCell>
                      <TableCell className="text-right">{formatPkr(l.budget)}</TableCell>
                      <TableCell className="text-right">{formatPkr(l.actual)}</TableCell>
                      <TableCell className={cn('text-right', variance < 0 && 'text-destructive')}>{formatPkr(variance)}</TableCell>
                      <TableCell className="text-right">{l.budget > 0 ? `${Math.round((l.actual / l.budget) * 100)}%` : '—'}</TableCell>
                    </TableRow>
                  );
                })}
                <TableRow>
                  <TableCell colSpan={2} className="font-medium">
                    Total {s.title.toLowerCase()}
                  </TableCell>
                  <TableCell className="text-right font-medium">{formatPkr(s.lines.reduce((t, l) => t + l.budget, 0))}</TableCell>
                  <TableCell className="text-right font-medium">{formatPkr(s.lines.reduce((t, l) => t + l.actual, 0))}</TableCell>
                  <TableCell colSpan={2} />
                </TableRow>
              </TableBody>
            ))}
            <TableFooter>
              <TableRow>
                <TableCell colSpan={2} className="font-medium">
                  Surplus
                </TableCell>
                {(['budget', 'actual'] as const).map((k) => (
                  <TableCell key={k} className="text-right font-medium" data-testid={`surplus-${k}`}>
                    {formatPkr(income.reduce((t, l) => t + l[k], 0) - expense.reduce((t, l) => t + l[k], 0))}
                  </TableCell>
                ))}
                <TableCell colSpan={2} />
              </TableRow>
            </TableFooter>
          </Table>
        )}

        {canWrite && (accounts ?? []).length > 0 && (
          <BudgetForm
            key={fy}
            fyStartYear={fy}
            months={monthLabels}
            accounts={(accounts ?? []).map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }))}
            existing={existing}
          />
        )}
      </div>
    </>
  );
}
