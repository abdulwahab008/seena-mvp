'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { digestSubscriptionSchema, type DigestSubscriptionInput } from '@/lib/validation';
import { remove, setActive, subscribe } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type ReportOption = { key: string; label: string };

export function SubscribeForm({ reports }: { reports: ReportOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<DigestSubscriptionInput>({
    resolver: zodResolver(digestSubscriptionSchema),
    defaultValues: { reportKey: reports[0]?.key ?? '', cadence: 'daily', runAtLocal: '20:00', channel: 'in_app', timezone: 'Asia/Karachi', languageCode: 'en' },
  });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await subscribe(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Subscription saved.');
        router.refresh();
      }
    }),
  );
  const select = 'h-10 w-full rounded-md border bg-background px-3 text-sm';
  return (
    <form onSubmit={onSubmit} className="grid gap-4 sm:grid-cols-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="reportKey">Report</Label>
        <select id="reportKey" className={select} {...form.register('reportKey')}>
          {reports.map((r) => (
            <option key={r.key} value={r.key}>
              {r.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="cadence">How often</Label>
        <select id="cadence" className={select} {...form.register('cadence')}>
          <option value="daily">Every day</option>
          <option value="weekly">Every week (Monday)</option>
          <option value="monthly">Every month (1st)</option>
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="runAtLocal">Time (local)</Label>
        <Input id="runAtLocal" type="time" {...form.register('runAtLocal')} />
        {form.formState.errors.runAtLocal && <p className="text-xs text-destructive">{form.formState.errors.runAtLocal.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="channel">Deliver by</Label>
        <select id="channel" className={select} {...form.register('channel')}>
          <option value="in_app">In the app</option>
          <option value="whatsapp">WhatsApp</option>
          <option value="sms">SMS</option>
          <option value="email">Email</option>
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="languageCode">Language</Label>
        <select id="languageCode" className={select} {...form.register('languageCode')}>
          <option value="en">English</option>
          <option value="ur">Urdu</option>
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="timezone">Timezone</Label>
        <Input id="timezone" {...form.register('timezone')} />
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive sm:col-span-3" data-testid="subscribe-error">
          {error}
        </p>
      )}
      <div className="sm:col-span-3">
        <Button type="submit" disabled={pending} data-testid="subscribe">
          {pending ? 'Saving…' : 'Subscribe'}
        </Button>
      </div>
    </form>
  );
}

export function SubscriptionActions({ id, active }: { id: string; active: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (fn: () => Promise<{ error: string | null }>) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) router.refresh();
    });
  return (
    <span className="flex items-center gap-2">
      <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => setActive(id, !active))} data-testid={active ? 'deactivate' : 'activate'}>
        {active ? 'Pause' : 'Resume'}
      </Button>
      <Button size="sm" variant="ghost" disabled={pending} onClick={() => run(() => remove(id))}>
        Delete
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}
