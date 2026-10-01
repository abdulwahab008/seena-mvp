'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { exportDrilldown } from './actions';
import type { DrilldownExportInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';

export function ExportDrilldownButton({ filters }: { filters: DrilldownExportInput }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const onClick = () =>
    startTransition(async () => {
      setError(null);
      const result = await exportDrilldown(filters);
      if (result.error !== null) setError(result.error);
      else toast.success('Export queued — find it under Reports → Excel Exports.');
    });
  return (
    <div className="space-y-1">
      <Button type="button" variant="outline" size="sm" disabled={pending} onClick={onClick} data-testid="export-drilldown">
        {pending ? 'Queuing…' : 'Export these rows'}
      </Button>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
