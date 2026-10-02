'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { requestExport } from '@/app/(app)/reports/exports/actions';
import { Button } from '@/components/ui/button';

export function ExportCollectionButton({ classId }: { classId?: string }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const onClick = () =>
    startTransition(async () => {
      setError(null);
      const result = await requestExport({ datasetKey: 'fee_collection_monthly', classId });
      if (result.error !== null) setError(result.error);
      else toast.success('Export queued — find it under Reports → Excel Exports.');
    });
  return (
    <div className="space-y-1">
      <Button type="button" variant="outline" size="sm" disabled={pending} onClick={onClick} data-testid="export-collection">
        {pending ? 'Queuing…' : 'Export to Excel'}
      </Button>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
