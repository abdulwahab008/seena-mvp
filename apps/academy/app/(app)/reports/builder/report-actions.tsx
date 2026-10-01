'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { deleteReport, exportReport } from './actions';
import { Button } from '@/components/ui/button';

export function DeleteReportButton({ id }: { id: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <Button
      type="button"
      size="sm"
      variant="ghost"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await deleteReport(id);
          if (r.error) toast.error(r.error);
          else router.refresh();
        })
      }
    >
      Delete
    </Button>
  );
}

export function ExportReportButtons({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const run = (format: 'xlsx' | 'pdf') =>
    startTransition(async () => {
      setError(null);
      const r = await exportReport({ id, format, reason });
      if (r.error) setError(r.error);
      else toast.success('Export queued — find it under Reports → Excel Exports.');
    });
  return (
    <div className="space-y-2" data-testid="export-saved-report">
      <label className="block text-sm">
        <span className="text-muted-foreground">Reason (needed when the report contains personal data, 20+ characters)</span>
        <input value={reason} onChange={(e) => setReason(e.target.value)} className="mt-1 h-9 w-full rounded-md border bg-background px-2" aria-label="Export reason" />
      </label>
      <div className="flex gap-2">
        <Button type="button" variant="outline" size="sm" disabled={pending} onClick={() => run('xlsx')} data-testid="export-xlsx">
          Export to Excel
        </Button>
        <Button type="button" variant="outline" size="sm" disabled={pending} onClick={() => run('pdf')} data-testid="export-pdf">
          Export to PDF
        </Button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="export-error">
          {error}
        </p>
      )}
    </div>
  );
}
