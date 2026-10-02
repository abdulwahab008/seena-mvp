'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { requestExport } from '@/app/(app)/reports/exports/actions';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';

export function ExportDefaultersButton({ classId, bucket, hideHardship }: { classId?: string; bucket?: '1-30' | '31-60' | '61-90' | '90+'; hideHardship: boolean }) {
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);

  const onClick = () =>
    startTransition(async () => {
      setError(null);
      const result = await requestExport({ datasetKey: 'fee_defaulters', classId, bucket, hideHardship, reason });
      if (result.error !== null) setError(result.error);
      else toast.success('Export queued — find it under Reports → Excel Exports.');
    });

  return (
    <div className="space-y-2">
      <Textarea rows={2} placeholder="Reason for exporting guardian phone numbers (20+ characters)" value={reason} onChange={(e) => setReason(e.target.value)} data-testid="export-reason" />
      <Button type="button" variant="outline" disabled={pending} onClick={onClick} data-testid="export-defaulters">
        {pending ? 'Queuing…' : 'Export this list to Excel'}
      </Button>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
    </div>
  );
}
