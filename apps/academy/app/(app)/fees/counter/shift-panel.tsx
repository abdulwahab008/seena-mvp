'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  COUNTER_DENOMINATIONS,
  closeCounterSessionSchema,
  countersignCounterSessionSchema,
  createCashCounterSchema,
  openCounterSessionSchema,
  type CloseCounterSessionInput,
  type CountersignCounterSessionInput,
  type CreateCashCounterInput,
  type OpenCounterSessionInput,
} from '@/lib/validation';
import { formatPkrCompact } from '@/lib/format-money';
import { closeCounterSession, countersignCounterSession, createCashCounter, openCounterSession } from './shift-actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const selectClass = 'h-10 w-full rounded-md border bg-background px-3 text-sm';

export type CounterOption = { id: string; name: string; campusId: string; thresholdPaisa: number };
export type OpenSession = {
  id: string;
  counterName: string;
  openedAt: string;
  openingFloatPaisa: number;
  receiptCount: number;
  cashTotalPaisa: number;
  countersigned: boolean;
};
export type RecentSession = {
  id: string;
  counterName: string;
  openedByName: string;
  status: 'open' | 'closed' | 'closed_with_variance';
  openingFloatPaisa: number;
  systemTotalPaisa: number | null;
  declaredTotalPaisa: number | null;
  variancePaisa: number | null;
  countersigned: boolean;
  isOwnSession: boolean;
};

function useRun() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (fn: () => Promise<{ error: string | null }>, success?: string) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) {
        if (success) toast.success(success);
        router.refresh();
      }
    });
  return { pending, error, run };
}

function OpenForm({ counters }: { counters: CounterOption[] }) {
  const { pending, error, run } = useRun();
  const form = useForm<OpenCounterSessionInput>({
    resolver: zodResolver(openCounterSessionSchema),
    defaultValues: { counterId: counters[0]?.id ?? '', openingFloatPkr: 0 },
  });
  const onSubmit = form.handleSubmit((v) => run(() => openCounterSession(v), 'Counter opened.'));
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-3" noValidate data-testid="open-counter-form">
      <div className="space-y-1">
        <Label htmlFor="openCounter">Counter</Label>
        <select id="openCounter" className={selectClass} {...form.register('counterId')}>
          {counters.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="openFloat">Opening float (PKR)</Label>
        <Input id="openFloat" type="number" min={0} className="w-40" {...form.register('openingFloatPkr', { valueAsNumber: true })} />
      </div>
      <Button type="submit" disabled={pending} data-testid="open-counter">
        Open counter
      </Button>
      {(error || form.formState.errors.openingFloatPkr) && (
        <p role="alert" className="w-full text-sm text-destructive">
          {error ?? form.formState.errors.openingFloatPkr?.message}
        </p>
      )}
    </form>
  );
}

function CloseForm({ session }: { session: OpenSession }) {
  const { pending, error, run } = useRun();
  const form = useForm<CloseCounterSessionInput>({
    resolver: zodResolver(closeCounterSessionSchema),
    defaultValues: { sessionId: session.id, counts: Object.fromEntries(COUNTER_DENOMINATIONS.map((d) => [String(d), 0])) },
  });
  const counts = form.watch('counts');
  const declaredPaisa = COUNTER_DENOMINATIONS.reduce((sum, d) => sum + d * (Number(counts[String(d)]) || 0) * 100, 0);
  const expectedPaisa = session.openingFloatPaisa + session.cashTotalPaisa;
  const variancePaisa = declaredPaisa - expectedPaisa;

  const onSubmit = form.handleSubmit((v) => run(() => closeCounterSession(v), 'Shift closed.'));
  return (
    <form onSubmit={onSubmit} className="space-y-3" noValidate data-testid="close-counter-form">
      <p className="text-sm font-medium">Count the drawer</p>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
        {COUNTER_DENOMINATIONS.map((d) => (
          <div key={d} className="space-y-1">
            <Label htmlFor={`den-${d}`}>PKR {d}</Label>
            <Input id={`den-${d}`} type="number" min={0} {...form.register(`counts.${d}`, { valueAsNumber: true })} />
          </div>
        ))}
      </div>
      <dl className="grid gap-1 text-sm sm:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">System expects</dt>
          <dd data-testid="expected-total">{formatPkrCompact(expectedPaisa)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">You counted</dt>
          <dd data-testid="declared-total">{formatPkrCompact(declaredPaisa)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Variance</dt>
          <dd data-testid="variance-total" className={variancePaisa === 0 ? '' : 'font-medium text-destructive'}>
            {formatPkrCompact(variancePaisa)}
          </dd>
        </div>
      </dl>
      <Button type="submit" disabled={pending} data-testid="close-counter">
        Close shift
      </Button>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="close-error">
          {error}
        </p>
      )}
    </form>
  );
}

function CountersignForm({ sessionId }: { sessionId: string }) {
  const { pending, error, run } = useRun();
  const form = useForm<CountersignCounterSessionInput>({ resolver: zodResolver(countersignCounterSessionSchema), defaultValues: { sessionId, remark: '' } });
  const onSubmit = form.handleSubmit((v) => run(() => countersignCounterSession(v), 'Countersigned.'));
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor={`remark-${sessionId}`}>Remark</Label>
        <Input id={`remark-${sessionId}`} className="w-72" {...form.register('remark')} />
      </div>
      <Button type="submit" variant="outline" disabled={pending} data-testid="countersign">
        Countersign
      </Button>
      {(error || form.formState.errors.remark) && (
        <p role="alert" className="w-full text-sm text-destructive">
          {error ?? form.formState.errors.remark?.message}
        </p>
      )}
    </form>
  );
}

function CreateCounterForm({ campuses }: { campuses: { id: string; name: string }[] }) {
  const { pending, error, run } = useRun();
  const form = useForm<CreateCashCounterInput>({
    resolver: zodResolver(createCashCounterSchema),
    defaultValues: { campusId: campuses[0]?.id ?? '', name: '', thresholdPkr: 500 },
  });
  const onSubmit = form.handleSubmit((v) =>
    run(async () => {
      const r = await createCashCounter(v);
      if (!r.error) form.reset({ campusId: v.campusId, name: '', thresholdPkr: v.thresholdPkr });
      return r;
    }, 'Counter added.'),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-3" noValidate data-testid="create-counter-form">
      <div className="space-y-1">
        <Label htmlFor="ctrCampus">Campus</Label>
        <select id="ctrCampus" className={selectClass} {...form.register('campusId')}>
          {campuses.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="ctrName">Counter name</Label>
        <Input id="ctrName" className="w-48" {...form.register('name')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="ctrThreshold">Variance threshold (PKR)</Label>
        <Input id="ctrThreshold" type="number" min={0} className="w-40" {...form.register('thresholdPkr', { valueAsNumber: true })} />
      </div>
      <Button type="submit" disabled={pending} data-testid="create-counter">
        Add counter
      </Button>
      {(error || form.formState.errors.name) && (
        <p role="alert" className="w-full text-sm text-destructive">
          {error ?? form.formState.errors.name?.message}
        </p>
      )}
    </form>
  );
}

export function ShiftPanel({ counters, openSession }: { counters: CounterOption[]; openSession: OpenSession | null }) {
  return (
    <Card data-testid="shift-panel">
      <CardContent className="space-y-4 pt-6">
        {openSession ? (
          <>
            <div>
              <p className="text-sm font-medium" data-testid="open-session-label">
                {openSession.counterName} is open
              </p>
              <p className="text-xs text-muted-foreground">
                Float {formatPkrCompact(openSession.openingFloatPaisa)} · {openSession.receiptCount} cash receipts totalling {formatPkrCompact(openSession.cashTotalPaisa)}
              </p>
            </div>
            <CloseForm session={openSession} />
          </>
        ) : (
          <>
            <p className="text-sm text-muted-foreground" data-testid="no-open-session">
              No counter is open. Open one before taking cash.
            </p>
            {counters.length === 0 ? (
              <p className="text-sm text-muted-foreground">No counter is set up for your campus yet. Ask the Principal to add one.</p>
            ) : (
              <OpenForm counters={counters} />
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}

export function ManagePanel({
  campuses,
  recent,
  counters,
}: {
  campuses: { id: string; name: string }[];
  recent: RecentSession[];
  counters: { id: string; name: string; campusName: string; thresholdPaisa: number }[];
}) {
  return (
    <Card data-testid="manage-panel">
      <CardContent className="space-y-6 pt-6">
        <div className="space-y-2">
          <h2 className="text-base font-semibold">Counters</h2>
          {counters.length > 0 ? (
            <ul className="divide-y rounded-md border text-sm" data-testid="counter-list">
              {counters.map((c) => (
                <li key={c.id} className="flex flex-wrap justify-between gap-2 px-3 py-2">
                  <span className="font-medium">{c.name}</span>
                  <span className="text-muted-foreground">
                    {c.campusName} · countersign above {formatPkrCompact(c.thresholdPaisa)}
                  </span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">No counters yet. Add one for each place cash is taken.</p>
          )}
          <CreateCounterForm campuses={campuses} />
        </div>
        <div className="space-y-2">
          <h2 className="text-base font-semibold">Recent shifts</h2>
          {recent.length === 0 ? (
            <p className="text-sm text-muted-foreground">No shifts yet.</p>
          ) : (
            <ul className="divide-y text-sm">
              {recent.map((s) => (
                <li key={s.id} className="space-y-2 py-3" data-testid={`shift-${s.counterName}`}>
                  <div className="flex flex-wrap items-baseline justify-between gap-2">
                    <span className="font-medium">
                      {s.counterName} · {s.openedByName}
                    </span>
                    <span className="text-muted-foreground">
                      {s.status === 'open'
                        ? 'Open'
                        : `Expected ${formatPkrCompact(s.openingFloatPaisa + (s.systemTotalPaisa ?? 0))} · counted ${formatPkrCompact(s.declaredTotalPaisa ?? 0)} · variance ${formatPkrCompact(s.variancePaisa ?? 0)}`}
                    </span>
                  </div>
                  {s.status === 'open' && !s.countersigned && !s.isOwnSession && <CountersignForm sessionId={s.id} />}
                  {s.status === 'open' && s.countersigned && <p className="text-xs text-muted-foreground">Countersigned. The shift can now be closed.</p>}
                </li>
              ))}
            </ul>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
