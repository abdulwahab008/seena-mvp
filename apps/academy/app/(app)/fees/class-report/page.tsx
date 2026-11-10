import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { hasFeeAccess } from '@/lib/auth/fee-access';
import { formatDatePk, todayPk } from '@/lib/dates';
import { PrintButton } from '@/components/print-button';
import { Button } from '@/components/ui/button';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const pkr = (paisa: number) => new Intl.NumberFormat('en-PK', { maximumFractionDigits: 0 }).format(paisa / 100);
const OTHER = [
  { href: '/fees/reports', label: 'Daily collection and closing report' },
  { href: '/fees/defaulters', label: 'Fee defaulter report' },
  { href: '/fees/commitments', label: 'Fee commitments and bad debts' },
  { href: '/fees/concessions', label: 'Fee concession report' },
  { href: '/fees/sibling-discounts', label: 'Sibling discount report' },
  { href: '/fees/challans', label: 'Students challans report' },
  { href: '/fees/no-dues', label: 'Security deposits and no-dues' },
  { href: '/fees/analytics', label: 'Fee analytics' },
];

export default async function FeeClassReportPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !hasFeeAccess(actor.role)) notFound();
  const f = await searchParams;
  const today = todayPk();
  const to = f.to && DATE.test(f.to) ? f.to : today;
  const from = f.from && DATE.test(f.from) ? f.from : `${to.slice(0, 7)}-01`;
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fee_class_report', { p_from: from, p_to: to });
  const rows = data ?? [];
  const total = (k: keyof (typeof rows)[number]) => rows.reduce((t, r) => t + Number(r[k]), 0);
  const billed = total('billed_paisa') - total('concession_paisa');
  const efficiency = billed > 0 ? Math.round((total('collected_paisa') / billed) * 100) : null;
  const money = ['billed_paisa', 'concession_paisa', 'collected_paisa', 'written_off_paisa', 'balance_paisa'] as const;
  const aging = ['due_0_30_paisa', 'due_31_60_paisa', 'due_61_90_paisa', 'due_90_plus_paisa'] as const;

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Fee reports</h1>
          <p className="text-sm text-muted-foreground">
            Class-wise billing and collection from {formatDatePk(from)} to {formatDatePk(to)}, and how long unpaid fees have been overdue.
          </p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      <form method="get" className="flex flex-wrap items-end gap-2 text-sm print:hidden">
        <label className="space-y-1">
          <span className="block text-muted-foreground">From</span>
          <input type="date" name="from" defaultValue={from} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">To</span>
          <input type="date" name="to" defaultValue={to} max={today} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <Button type="submit" size="sm" variant="outline">
          Show
        </Button>
      </form>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Stat label="Billed after concessions" value={`PKR ${pkr(billed)}`} />
        <Stat label="Collected" value={`PKR ${pkr(total('collected_paisa'))}`} tone="success" />
        <Stat label="Collection efficiency" value={efficiency === null ? '—' : `${efficiency}%`} hint="Collected against billed in this period" />
        <Stat label="Still owed" value={`PKR ${pkr(total('balance_paisa'))}`} tone={total('balance_paisa') > 0 ? 'warning' : 'default'} hint={`As of ${formatDatePk(to)}`} />
      </section>
      {error ? (
        <p className="text-sm text-destructive">Could not load the report. Try again.</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No fee activity in this period.</p>
      ) : (
        <>
          <section className="space-y-2">
            <h2 className="text-lg font-semibold">Class-wise fee collection</h2>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Class</TableHead>
                  <TableHead className="text-right">Students</TableHead>
                  <TableHead className="text-right">Billed</TableHead>
                  <TableHead className="text-right">Concession</TableHead>
                  <TableHead className="text-right">Collected</TableHead>
                  <TableHead className="text-right">Written off</TableHead>
                  <TableHead className="text-right">Balance</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => (
                  <TableRow key={r.class_level_id} data-testid="class-fee-row">
                    <TableCell className="font-medium">{r.class_name}</TableCell>
                    <TableCell className="tabular text-right">{r.students}</TableCell>
                    {money.map((k) => (
                      <TableCell key={k} className="tabular text-right">
                        {pkr(r[k])}
                      </TableCell>
                    ))}
                  </TableRow>
                ))}
              </TableBody>
              <TableFooter>
                <TableRow>
                  <TableCell>Total</TableCell>
                  <TableCell className="tabular text-right">{total('students')}</TableCell>
                  {money.map((k) => (
                    <TableCell key={k} className="tabular text-right">
                      {pkr(total(k))}
                    </TableCell>
                  ))}
                </TableRow>
              </TableFooter>
            </Table>
          </section>
          <section className="space-y-2">
            <h2 className="text-lg font-semibold">Receivables aging</h2>
            <p className="text-sm text-muted-foreground">Unpaid challans by days past their due date, as of {formatDatePk(to)}.</p>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Class</TableHead>
                  <TableHead className="text-right">0–30 days</TableHead>
                  <TableHead className="text-right">31–60 days</TableHead>
                  <TableHead className="text-right">61–90 days</TableHead>
                  <TableHead className="text-right">Over 90 days</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => (
                  <TableRow key={r.class_level_id} data-testid="aging-row">
                    <TableCell className="font-medium">{r.class_name}</TableCell>
                    {aging.map((k) => (
                      <TableCell key={k} className={`tabular text-right ${k === 'due_90_plus_paisa' && r[k] > 0 ? 'font-medium text-destructive' : ''}`}>
                        {pkr(r[k])}
                      </TableCell>
                    ))}
                  </TableRow>
                ))}
              </TableBody>
              <TableFooter>
                <TableRow>
                  <TableCell>Total</TableCell>
                  {aging.map((k) => (
                    <TableCell key={k} className="tabular text-right">
                      {pkr(total(k))}
                    </TableCell>
                  ))}
                </TableRow>
              </TableFooter>
            </Table>
          </section>
        </>
      )}
      <section className="space-y-2 print:hidden">
        <h2 className="text-lg font-semibold">More fee reports</h2>
        <ul className="divide-y rounded-lg border">
          {OTHER.map((r, i) => (
            <li key={r.href} className="flex items-center gap-3 px-4 py-2.5 text-sm">
              <span className="tabular w-6 text-muted-foreground">{i + 1}</span>
              <span className="flex-1">{r.label}</span>
              <Link href={r.href} className="font-medium text-primary hover:underline">
                View
              </Link>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
