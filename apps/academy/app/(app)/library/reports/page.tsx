import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { one } from '@/lib/hr/current-role';
import { formatDatePk, todayPk } from '@/lib/dates';
import { pkr } from '@/lib/rpc-action';
import { cn } from '@/lib/utils';
import { PrintButton } from '@/components/print-button';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const REPORTS = { circulation: 'Circulation register', overdue: 'Overdue report', fines: 'Fines summary' } as const;
type Report = keyof typeof REPORTS;
const daysBetween = (from: string, to: string) => Math.round((Date.parse(to) - Date.parse(from)) / 86_400_000);

export default async function LibraryReportsPage({ searchParams }: { searchParams: Promise<{ report?: string; from?: string; to?: string }> }) {
  const f = await searchParams;
  const report: Report = f.report && f.report in REPORTS ? (f.report as Report) : 'circulation';
  const today = todayPk();
  const to = f.to && DATE.test(f.to) ? f.to : today;
  const from = f.from && DATE.test(f.from) ? f.from : `${to.slice(0, 7)}-01`;
  const supabase = await supabaseServer();

  const loanSelect = 'id, borrower_id, borrower_role, issued_at, due_on, returned_at, fine_amount, copy:copy_id(accession_no, title:title_id(title))';
  const [{ data: loans }, { data: fines }] = await Promise.all([
    report === 'circulation'
      ? supabase.from('library_loan').select(loanSelect).gte('issued_at', `${from}T00:00:00+05:00`).lte('issued_at', `${to}T23:59:59+05:00`).order('issued_at', { ascending: false }).limit(500)
      : report === 'overdue'
        ? supabase.from('library_loan').select(loanSelect).is('returned_at', null).lt('due_on', today).order('due_on').limit(500)
        : Promise.resolve({ data: [] }),
    report === 'fines' ? supabase.from('library_fine').select('borrower_id, amount, status') : Promise.resolve({ data: [] }),
  ]);
  const ids = [...new Set([...(loans ?? []).map((l) => l.borrower_id), ...(fines ?? []).map((x) => x.borrower_id)])];
  const [{ data: students }, { data: staff }, { data: owed }] = await Promise.all([
    ids.length ? supabase.from('student').select('id, name_en').in('id', ids) : Promise.resolve({ data: [] as { id: string; name_en: string }[] }),
    ids.length ? supabase.from('app_user').select('user_id, full_name').in('user_id', ids) : Promise.resolve({ data: [] as { user_id: string; full_name: string }[] }),
    report === 'overdue' && ids.length
      ? supabase.from('library_fine').select('loan_id, amount').eq('status', 'outstanding').in('borrower_id', ids)
      : Promise.resolve({ data: [] as { loan_id: string; amount: number }[] }),
  ]);
  const names = new Map<string, string>([...(students ?? []).map((s) => [s.id, s.name_en] as const), ...(staff ?? []).map((s) => [s.user_id, s.full_name] as const)]);
  const fineByLoan = new Map<string, number>();
  for (const o of owed ?? []) fineByLoan.set(o.loan_id, (fineByLoan.get(o.loan_id) ?? 0) + o.amount);

  const perBorrower = new Map<string, { outstanding: number; settled: number; waived: number }>();
  for (const x of fines ?? []) {
    const e = perBorrower.get(x.borrower_id) ?? { outstanding: 0, settled: 0, waived: 0 };
    e[x.status] += x.amount;
    perBorrower.set(x.borrower_id, e);
  }
  const fineRows = [...perBorrower.entries()].map(([id, v]) => ({ id, name: names.get(id) ?? 'Unknown borrower', ...v })).sort((a, b) => b.outstanding - a.outstanding);
  const fineTotal = (k: 'outstanding' | 'settled' | 'waived') => fineRows.reduce((t, r) => t + r[k], 0);
  const title = (l: { copy: unknown }) => {
    const c = one(l.copy as { accession_no: string; title: { title: string } | { title: string }[] | null } | null);
    return { accession: c?.accession_no ?? '', title: one(c?.title)?.title ?? '' };
  };
  const pill = (active: boolean) => cn('rounded-full border px-3 py-1 text-sm', active ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted');

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Library reports</h1>
          <p className="text-sm text-muted-foreground">Books issued and returned, loans past their due date, and fines by borrower.</p>
        </div>
        <div className="flex gap-2 print:hidden">
          <Link href="/library/titles" className="h-9 px-2 text-sm leading-9 text-muted-foreground underline">
            Catalogue
          </Link>
          <PrintButton />
        </div>
      </div>
      <nav className="flex flex-wrap gap-2 print:hidden" aria-label="Report">
        {(Object.keys(REPORTS) as Report[]).map((r) => (
          <Link key={r} href={`/library/reports?report=${r}`} className={pill(r === report)} aria-current={r === report ? 'page' : undefined}>
            {REPORTS[r]}
          </Link>
        ))}
      </nav>

      {report === 'circulation' && (
        <>
          <form method="get" className="flex flex-wrap items-end gap-2 text-sm print:hidden">
            <input type="hidden" name="report" value="circulation" />
            <input type="date" name="from" defaultValue={from} aria-label="From" className="h-9 rounded-md border bg-background px-2" />
            <input type="date" name="to" defaultValue={to} aria-label="To" className="h-9 rounded-md border bg-background px-2" />
            <Button type="submit" size="sm" variant="outline">
              Show
            </Button>
          </form>
          {(loans ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">No books were issued in this period.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Issued</TableHead>
                  <TableHead>Book</TableHead>
                  <TableHead>Accession</TableHead>
                  <TableHead>Borrower</TableHead>
                  <TableHead>Due</TableHead>
                  <TableHead>Returned</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">Fine</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(loans ?? []).map((l) => {
                  const t = title(l);
                  const late = l.returned_at ? l.returned_at.slice(0, 10) > l.due_on : l.due_on < today;
                  return (
                    <TableRow key={l.id} data-testid="circulation-row">
                      <TableCell className="whitespace-nowrap">{formatDatePk(l.issued_at.slice(0, 10))}</TableCell>
                      <TableCell className="font-medium">{t.title}</TableCell>
                      <TableCell className="tabular font-mono">{t.accession}</TableCell>
                      <TableCell>{names.get(l.borrower_id) ?? ''}</TableCell>
                      <TableCell className="whitespace-nowrap">{formatDatePk(l.due_on)}</TableCell>
                      <TableCell className="whitespace-nowrap">{l.returned_at ? formatDatePk(l.returned_at.slice(0, 10)) : ''}</TableCell>
                      <TableCell>
                        <Badge variant={l.returned_at ? (late ? 'warning' : 'success') : late ? 'destructive' : 'outline'}>
                          {l.returned_at ? (late ? 'Returned late' : 'Returned') : late ? 'Overdue' : 'Out'}
                        </Badge>
                      </TableCell>
                      <TableCell className="tabular text-right">{l.fine_amount ? pkr(l.fine_amount) : ''}</TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          )}
        </>
      )}

      {report === 'overdue' &&
        ((loans ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No book is overdue.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Book</TableHead>
                <TableHead>Accession</TableHead>
                <TableHead>Borrower</TableHead>
                <TableHead>Due</TableHead>
                <TableHead className="text-right">Days overdue</TableHead>
                <TableHead className="text-right">Fine owed</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(loans ?? []).map((l) => {
                const t = title(l);
                return (
                  <TableRow key={l.id} data-testid="overdue-row">
                    <TableCell className="font-medium">{t.title}</TableCell>
                    <TableCell className="tabular font-mono">{t.accession}</TableCell>
                    <TableCell>{names.get(l.borrower_id) ?? ''}</TableCell>
                    <TableCell className="whitespace-nowrap">{formatDatePk(l.due_on)}</TableCell>
                    <TableCell className="tabular text-right text-destructive">{daysBetween(l.due_on, today)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(fineByLoan.get(l.id) ?? 0)}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        ))}

      {report === 'fines' && (
        <>
          <section aria-label="Summary" className="grid gap-3 sm:grid-cols-3">
            <Stat label="Outstanding" value={pkr(fineTotal('outstanding'))} tone={fineTotal('outstanding') > 0 ? 'warning' : 'default'} />
            <Stat label="Collected" value={pkr(fineTotal('settled'))} tone="success" />
            <Stat label="Waived" value={pkr(fineTotal('waived'))} />
          </section>
          {fineRows.length === 0 ? (
            <p className="text-sm text-muted-foreground">No library fines yet.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Borrower</TableHead>
                  <TableHead className="text-right">Outstanding</TableHead>
                  <TableHead className="text-right">Collected</TableHead>
                  <TableHead className="text-right">Waived</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {fineRows.map((r) => (
                  <TableRow key={r.id} data-testid="fine-row">
                    <TableCell className="font-medium">{r.name}</TableCell>
                    <TableCell className="tabular text-right">{pkr(r.outstanding)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(r.settled)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(r.waived)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </>
      )}
    </div>
  );
}
