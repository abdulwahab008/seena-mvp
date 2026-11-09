import Link from 'next/link';
import { notFound } from 'next/navigation';
import { Repeat } from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatPkr } from '@/lib/challan/html';
import { formatDatePk, todayPk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { EmptyState } from '@/components/ui/empty-state';
import { PostDueButton, RecurringActiveButton, RecurringForm, type RecurringValues } from './forms';

export const dynamic = 'force-dynamic';

const READERS = ['super_admin', 'owner', 'principal', 'accountant'];
const WRITERS = ['super_admin', 'owner', 'accountant'];
const FREQUENCY: Record<string, string> = { monthly: 'Every month', quarterly: 'Every quarter', yearly: 'Every year' };
const rupees = (paisa: number) => (paisa ? String(paisa / 100) : '');

export default async function RecurringPage({ searchParams }: { searchParams: Promise<{ edit?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !READERS.includes(actor.role)) notFound();
  const canWrite = WRITERS.includes(actor.role);
  const { edit } = await searchParams;

  const supabase = await supabaseServer();
  const [{ data: templates }, { data: accounts }, { data: costCenters }] = await Promise.all([
    supabase
      .from('gl_recurring_journal')
      .select(
        'id, name, narration, frequency, next_run, is_active, gl_recurring_journal_line(account_id, cost_center_id, debit, credit, memo, account:account_id(code, name), cost_center:cost_center_id(code)), gl_recurring_journal_run(run_date)',
      )
      .order('next_run'),
    supabase.from('gl_account').select('id, code, name').eq('is_active', true).order('code'),
    supabase.from('gl_cost_center').select('id, code, name').eq('is_active', true).order('code'),
  ]);
  const today = todayPk();
  const due = (templates ?? []).filter((t) => t.is_active && t.next_run <= today).length;
  const editing = canWrite ? (templates ?? []).find((t) => t.id === edit) : undefined;
  const accountOptions = (accounts ?? []).map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }));
  const costCenterOptions = (costCenters ?? []).map((c) => ({ id: c.id, label: `${c.code} · ${c.name}` }));
  const initial: RecurringValues | undefined = editing && {
    name: editing.name,
    narration: editing.narration,
    frequency: editing.frequency as RecurringValues['frequency'],
    nextRun: editing.next_run,
    lines: (editing.gl_recurring_journal_line ?? []).map((l) => ({
      accountId: l.account_id,
      costCenterId: l.cost_center_id ?? '',
      debit: rupees(l.debit),
      credit: rupees(l.credit),
      memo: l.memo ?? '',
    })),
  };

  if ((accounts ?? []).length === 0) {
    return (
      <>
        <PageHeader title="Recurring vouchers" description="Vouchers that repeat every month, quarter or year." />
        <p className="text-sm text-muted-foreground">Set up the chart of accounts under General Ledger first.</p>
      </>
    );
  }

  return (
    <>
      <PageHeader
        title="Recurring vouchers"
        description="Vouchers that repeat, such as rent or insurance. Post due now posts every run that has fallen due, through the same checks as a voucher typed by hand."
        actions={canWrite ? <PostDueButton due={due} /> : null}
      />
      <div className="space-y-6">
        {canWrite && (
          <RecurringForm key={editing?.id ?? 'new'} id={editing?.id} initial={initial} accounts={accountOptions} costCenters={costCenterOptions} />
        )}
        {(templates ?? []).length === 0 ? (
          <EmptyState icon={Repeat} title="No recurring vouchers yet" description="Add one for any voucher you post on a schedule." />
        ) : (
          <div className="space-y-2">
            {(templates ?? []).map((t) => {
              const lines = t.gl_recurring_journal_line ?? [];
              const total = lines.reduce((s, l) => s + l.debit, 0);
              const runs = (t.gl_recurring_journal_run ?? []).length;
              return (
                <div key={t.id} className="rounded-md border p-3 text-sm" data-testid="recurring-journal">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span>
                      <span className="font-medium">{t.name}</span> · {FREQUENCY[t.frequency]} · next {formatDatePk(t.next_run)}{' '}
                      {!t.is_active && <Badge variant="outline">paused</Badge>}
                      {t.is_active && t.next_run <= today && <Badge variant="warning">due</Badge>}
                    </span>
                    <span className="flex items-center gap-2">
                      {formatPkr(total)}
                      {canWrite && (
                        <>
                          <Link href={`/accounts/recurring?edit=${t.id}`} className="rounded-md px-2 py-1 hover:bg-muted">
                            Edit
                          </Link>
                          <RecurringActiveButton id={t.id} name={t.name} isActive={t.is_active} />
                        </>
                      )}
                    </span>
                  </div>
                  <ul className="mt-1 text-muted-foreground">
                    {lines.map((l, i) => {
                      const acc = Array.isArray(l.account) ? l.account[0] : l.account;
                      const cc = Array.isArray(l.cost_center) ? l.cost_center[0] : l.cost_center;
                      return (
                        <li key={i}>
                          {l.debit > 0 ? 'Dr' : 'Cr'} {acc?.code} {acc?.name} · {formatPkr(l.debit || l.credit)}
                          {cc && <span className="font-mono"> · {cc.code}</span>}
                        </li>
                      );
                    })}
                  </ul>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {t.narration} · posted {runs} {runs === 1 ? 'time' : 'times'}
                  </p>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </>
  );
}
