'use client';

import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { exportRequestSchema, type ExportRequestInput } from '@/lib/validation';
import { requestExport } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';

export type DatasetOption = { key: 'students' | 'fee_collection'; label: string };

export function ExportForm({ datasets }: { datasets: DatasetOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [serverError, setServerError] = useState<string | null>(null);
  const form = useForm<ExportRequestInput>({ resolver: zodResolver(exportRequestSchema), defaultValues: { datasetKey: datasets[0]?.key ?? 'students', reason: '' } });
  const dataset = form.watch('datasetKey');

  const onSubmit = form.handleSubmit((values) => {
    setServerError(null);
    startTransition(async () => {
      const result = await requestExport(values);
      if (result.error !== null) setServerError(result.error);
      else {
        toast.success(result.deduplicated ? 'That export is already being prepared.' : 'Export queued. You can leave this page — we will notify you.');
        router.refresh();
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid gap-4 sm:grid-cols-2" noValidate>
      <div className="space-y-2">
        <Label htmlFor="datasetKey">Export</Label>
        <select id="datasetKey" className="h-10 w-full rounded-md border bg-background px-3 text-sm" {...form.register('datasetKey')}>
          {datasets.map((d) => (
            <option key={d.key} value={d.key}>
              {d.label}
            </option>
          ))}
        </select>
      </div>
      {dataset === 'fee_collection' && (
        <>
          <div className="space-y-2">
            <Label htmlFor="from">From</Label>
            <Input id="from" type="date" {...form.register('from')} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="to">To</Label>
            <Input id="to" type="date" {...form.register('to')} />
          </div>
        </>
      )}
      <div className="space-y-2 sm:col-span-2">
        <Label htmlFor="reason">Reason (required, 20+ characters, when the export contains personal data)</Label>
        <Textarea id="reason" rows={2} {...form.register('reason')} />
      </div>
      {serverError && (
        <p role="alert" className="text-sm text-destructive sm:col-span-2">
          {serverError}
        </p>
      )}
      <div className="sm:col-span-2">
        <Button type="submit" disabled={pending || datasets.length === 0}>
          {pending ? 'Queuing…' : 'Request Excel export'}
        </Button>
      </div>
    </form>
  );
}

// Keeps the list fresh while a file is being built; stops once nothing is pending.
export function AutoRefresh({ active }: { active: boolean }) {
  const router = useRouter();
  useEffect(() => {
    if (!active) return;
    const t = setInterval(() => router.refresh(), 4000);
    return () => clearInterval(t);
  }, [active, router]);
  return null;
}
