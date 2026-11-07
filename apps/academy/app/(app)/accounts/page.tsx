import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatPkr } from '@/lib/challan/html';
import { formatDatePk, todayPk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { AccountForm, BackfillButton, HeadAccountSelect, ReverseButton, SetupChartButton, VoucherForm } from './ledger-forms';

export const dynamic = 'force-dynamic';

const READERS = ['super_admin', 'owner', 'principal', 'accountant'];
const WRITERS = ['super_admin', 'owner', 'accountant'];
const TABS = [
  { id: 'journal', label: 'Vouchers' },
  { id: 'trial', label: 'Trial balance' },
  { id: 'income', label: 'Income statement' },
  { id: 'balance', label: 'Balance sheet' },
  { id: 'chart', label: 'Chart of accounts' },
  { id: 'mapping', label: 'Posting accounts' },
] as const;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

// Pakistani schools keep a July to June financial year.
function fyStart(today: string): string {
  const y = Number(today.slice(0, 4));
  return `${Number(today.slice(5, 7)) >= 7 ? y : y - 1}-07-01`;
}
const TYPE_LABEL: Record<string, string> = { asset: 'Asset', liability: 'Liability', equity: 'Equity', income: 'Income', expense: 'Expense' };

export default async function AccountsPage({ searchParams }: { searchParams: Promise<{ tab?: string; asOf?: string; from?: string; to?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !READERS.includes(actor.role)) notFound();
  const canWrite = WRITERS.includes(actor.role);
  const sp = await searchParams;
  const tab = TABS.some((t) => t.id === sp.tab) ? sp.tab! : 'journal';
  const asOf = sp.asOf && DATE.test(sp.asOf) ? sp.asOf : todayPk();
  const to = sp.to && DATE.test(sp.to) ? sp.to : todayPk();
  const from = sp.from && DATE.test(sp.from) ? sp.from : fyStart(to);

  const supabase = await supabaseServer();
  const { data: accounts } = await supabase.from('gl_account').select('id, code, name, type, is_active').order('code');

  if ((accounts ?? []).length === 0) {
    return (
      <>
        <PageHeader title="Accounts" description="General ledger: chart of accounts, journal vouchers and trial balance." />
        {canWrite ? <SetupChartButton /> : <p className="text-sm text-muted-foreground">The accountant has not set up the ledger yet.</p>}
      </>
    );
  }

  return (
    <>
      <PageHeader title="Accounts" description="General ledger: vouchers, trial balance, income statement and balance sheet. Fees, expenses, payroll and shop sales post here on their own. Posted vouchers are permanent; correct one by reversing it." />
      <nav className="mb-4 flex gap-2" aria-label="Ledger views">
        {TABS.map((t) => (
          <Link key={t.id} href={`/accounts?tab=${t.id}`} className={cn('rounded-full border px-3 py-1 text-sm', t.id === tab ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted')}>
            {t.label}
          </Link>
        ))}
      </nav>

      {tab === 'journal' && <JournalTab canWrite={canWrite} accounts={(accounts ?? []).filter((a) => a.is_active)} />}
      {tab === 'trial' && <TrialTab asOf={asOf} />}
      {tab === 'income' && <IncomeTab from={from} to={to} />}
      {tab === 'balance' && <BalanceTab asOf={asOf} />}
      {tab === 'mapping' && <MappingTab canWrite={canWrite} accounts={(accounts ?? []).filter((a) => a.is_active)} />}
      {tab === 'chart' && (
        <div className="grid gap-6 lg:grid-cols-[1fr_20rem]">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Code</TableHead>
                <TableHead>Account</TableHead>
                <TableHead>Type</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(accounts ?? []).map((a) => (
                <TableRow key={a.id} data-testid="gl-account">
                  <TableCell className="font-mono">{a.code}</TableCell>
                  <TableCell>
                    {a.name} {!a.is_active && <Badge variant="outline">inactive</Badge>}
                  </TableCell>
                  <TableCell>{TYPE_LABEL[a.type]}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          {canWrite && <AccountForm />}
        </div>
      )}
    </>
  );
}

async function JournalTab({ canWrite, accounts }: { canWrite: boolean; accounts: { id: string; code: string; name: string }[] }) {
  const supabase = await supabaseServer();
  const { data: entries } = await supabase
    .from('journal_entry')
    .select('id, entry_no, entry_date, narration, reversal_of, reversed_by, source_kind, journal_line(debit, credit, account:account_id(code, name))')
    .order('created_at', { ascending: false })
    .limit(50);
  return (
    <div className="space-y-6">
      {canWrite && <VoucherForm accounts={accounts.map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }))} />}
      {canWrite && (
        <div className="flex flex-wrap items-center gap-3 text-sm text-muted-foreground">
          <BackfillButton />
          <span>Fees, paid expenses, payroll, shop cash sales and petty cash post here automatically. Use this once to post records from before Accounts was set up.</span>
        </div>
      )}
      <div className="space-y-2">
        {(entries ?? []).length === 0 && <p className="text-sm text-muted-foreground">No vouchers yet.</p>}
        {(entries ?? []).map((e) => {
          const total = (e.journal_line ?? []).reduce((s, l) => s + l.debit, 0);
          return (
            <div key={e.id} className="rounded-md border p-3 text-sm" data-testid="journal-entry">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span>
                  <span className="font-mono font-medium">{e.entry_no}</span> · {formatDatePk(e.entry_date)} · {e.narration}{' '}
                  {e.source_kind && <Badge variant="info">auto</Badge>} {e.reversed_by && <Badge variant="outline">reversed</Badge>}
                </span>
                <span className="flex items-center gap-2">
                  {formatPkr(total)}
                  {canWrite && !e.reversed_by && !e.reversal_of && <ReverseButton entryId={e.id} entryNo={e.entry_no} />}
                </span>
              </div>
              <ul className="mt-1 text-muted-foreground">
                {(e.journal_line ?? []).map((l, i) => {
                  const acc = Array.isArray(l.account) ? l.account[0] : l.account;
                  return (
                    <li key={i}>
                      {l.debit > 0 ? 'Dr' : 'Cr'} {acc?.code} {acc?.name} · {formatPkr(l.debit || l.credit)}
                    </li>
                  );
                })}
              </ul>
            </div>
          );
        })}
      </div>
    </div>
  );
}

async function TrialTab({ asOf }: { asOf: string }) {
  const supabase = await supabaseServer();
  const { data: rows } = await supabase.rpc('trial_balance', { p_as_of: asOf });
  const debit = (rows ?? []).reduce((s, r) => s + r.debit, 0);
  const credit = (rows ?? []).reduce((s, r) => s + r.credit, 0);
  return (
    <div className="space-y-3">
      <form method="get" className="flex items-end gap-2 text-sm">
        <input type="hidden" name="tab" value="trial" />
        <label className="space-y-1">
          <span className="block text-muted-foreground">As of</span>
          <input name="asOf" type="date" defaultValue={asOf} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Code</TableHead>
            <TableHead>Account</TableHead>
            <TableHead className="text-right">Debits</TableHead>
            <TableHead className="text-right">Credits</TableHead>
            <TableHead className="text-right">Balance</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {(rows ?? []).map((r) => (
            <TableRow key={r.account_id} data-testid="trial-row">
              <TableCell className="font-mono">{r.code}</TableCell>
              <TableCell>{r.name}</TableCell>
              <TableCell className="text-right">{formatPkr(r.debit)}</TableCell>
              <TableCell className="text-right">{formatPkr(r.credit)}</TableCell>
              <TableCell className="text-right">{formatPkr(r.balance)}</TableCell>
            </TableRow>
          ))}
        </TableBody>
        <TableFooter>
          <TableRow>
            <TableCell colSpan={2} className="font-medium">
              Total {debit === credit ? '' : '(does not balance!)'}
            </TableCell>
            <TableCell className="text-right font-medium" data-testid="trial-debits">
              {formatPkr(debit)}
            </TableCell>
            <TableCell className="text-right font-medium" data-testid="trial-credits">
              {formatPkr(credit)}
            </TableCell>
            <TableCell />
          </TableRow>
        </TableFooter>
      </Table>
    </div>
  );
}

function DateForm({ tab, fields }: { tab: string; fields: { name: string; label: string; value: string }[] }) {
  return (
    <form method="get" className="flex flex-wrap items-end gap-2 text-sm">
      <input type="hidden" name="tab" value={tab} />
      {fields.map((f) => (
        <label key={f.name} className="space-y-1">
          <span className="block text-muted-foreground">{f.label}</span>
          <input name={f.name} type="date" defaultValue={f.value} className="h-9 rounded-md border bg-background px-2" />
        </label>
      ))}
      <button type="submit" className="h-9 rounded-md border px-3">
        Show
      </button>
    </form>
  );
}

type StatementRow = { account_id: string | null; code: string | null; name: string; amount: number };

function StatementSection({ title, rows, testId }: { title: string; rows: StatementRow[]; testId: string }) {
  const total = rows.reduce((s, r) => s + r.amount, 0);
  return (
    <TableBody>
      <TableRow>
        <TableCell colSpan={3} className="bg-muted/50 font-medium">
          {title}
        </TableCell>
      </TableRow>
      {rows.map((r) => (
        <TableRow key={r.account_id ?? r.name}>
          <TableCell className="font-mono">{r.code}</TableCell>
          <TableCell>{r.name}</TableCell>
          <TableCell className="text-right">{formatPkr(r.amount)}</TableCell>
        </TableRow>
      ))}
      <TableRow>
        <TableCell colSpan={2} className="font-medium">
          Total {title.toLowerCase()}
        </TableCell>
        <TableCell className="text-right font-medium" data-testid={testId}>
          {formatPkr(total)}
        </TableCell>
      </TableRow>
    </TableBody>
  );
}

async function IncomeTab({ from, to }: { from: string; to: string }) {
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('income_statement', { p_from: from, p_to: to });
  const rows = data ?? [];
  const income = rows.filter((r) => r.type === 'income');
  const expense = rows.filter((r) => r.type === 'expense');
  const surplus = income.reduce((s, r) => s + r.amount, 0) - expense.reduce((s, r) => s + r.amount, 0);
  return (
    <div className="space-y-3">
      <DateForm tab="income" fields={[{ name: 'from', label: 'From', value: from }, { name: 'to', label: 'To', value: to }]} />
      <Table>
        <StatementSection title="Income" rows={income} testId="income-total" />
        <StatementSection title="Expenses" rows={expense} testId="expense-total" />
        <TableFooter>
          <TableRow>
            <TableCell colSpan={2} className="font-medium">
              {surplus >= 0 ? 'Surplus' : 'Deficit'} for the period
            </TableCell>
            <TableCell className="text-right font-medium" data-testid="period-surplus">
              {formatPkr(surplus)}
            </TableCell>
          </TableRow>
        </TableFooter>
      </Table>
    </div>
  );
}

async function BalanceTab({ asOf }: { asOf: string }) {
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('balance_sheet', { p_as_of: asOf });
  const rows = data ?? [];
  const assets = rows.filter((r) => r.type === 'asset');
  const liabilities = rows.filter((r) => r.type === 'liability');
  const equity = rows.filter((r) => r.type === 'equity');
  const sum = (rs: StatementRow[]) => rs.reduce((s, r) => s + r.amount, 0);
  const balanced = sum(assets) === sum(liabilities) + sum(equity);
  return (
    <div className="space-y-3">
      <DateForm tab="balance" fields={[{ name: 'asOf', label: 'As of', value: asOf }]} />
      <Table>
        <StatementSection title="Assets" rows={assets} testId="assets-total" />
        <StatementSection title="Liabilities" rows={liabilities} testId="liabilities-total" />
        <StatementSection title="Equity" rows={equity} testId="equity-total" />
        <TableFooter>
          <TableRow>
            <TableCell colSpan={2} className="font-medium">
              Liabilities and equity {balanced ? '' : '(does not balance!)'}
            </TableCell>
            <TableCell className="text-right font-medium">{formatPkr(sum(liabilities) + sum(equity))}</TableCell>
          </TableRow>
        </TableFooter>
      </Table>
    </div>
  );
}

async function MappingTab({ canWrite, accounts }: { canWrite: boolean; accounts: { code: string; name: string; type: string }[] }) {
  const supabase = await supabaseServer();
  const [{ data: feeHeads }, { data: expenseHeads }] = await Promise.all([
    supabase.from('fee_head').select('id, code, name_en, gl_code').eq('is_active', true).order('code'),
    supabase.from('expense_head').select('id, code, name_en, gl_code').eq('is_active', true).order('code'),
  ]);
  const options = (type: string) => accounts.filter((a) => a.type === type).map((a) => ({ code: a.code, label: `${a.code} · ${a.name}` }));
  const groups = [
    { kind: 'fee' as const, title: 'Fee heads', heads: feeHeads ?? [], options: options('income'), fallback: '4000' },
    { kind: 'expense' as const, title: 'Expense heads', heads: expenseHeads ?? [], options: options('expense'), fallback: '5900' },
  ];
  return (
    <div className="grid gap-6 lg:grid-cols-2">
      {groups.map((g) => (
        <div key={g.kind} className="space-y-2">
          <h2 className="font-medium">{g.title}</h2>
          {g.heads.length === 0 && <p className="text-sm text-muted-foreground">No {g.title.toLowerCase()} yet.</p>}
          {g.heads.map((h) => (
            <div key={h.id} className="grid grid-cols-[1fr_16rem] items-center gap-2 text-sm" data-testid={`${g.kind}-head-mapping`}>
              <span>
                {h.name_en} <span className="font-mono text-muted-foreground">{h.code}</span>
              </span>
              {canWrite ? (
                <HeadAccountSelect kind={g.kind} headId={h.id} headName={h.name_en} value={h.gl_code ?? ''} accounts={g.options} fallback={g.fallback} />
              ) : (
                <span className="font-mono">{h.gl_code ?? g.fallback}</span>
              )}
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}
