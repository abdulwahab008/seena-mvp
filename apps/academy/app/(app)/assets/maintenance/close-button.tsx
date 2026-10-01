'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { closeMaintenanceAction } from './actions';

export function CloseRepairButton({ maintenanceId }: { maintenanceId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="inline-flex items-center gap-2">
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="close-repair"
        onClick={() =>
          startTransition(async () => {
            const r = await closeMaintenanceAction(maintenanceId);
            setError(r.error);
            if (!r.error) router.refresh();
          })
        }
      >
        Close repair
      </Button>
      {error && (
        <span role="alert" className="text-xs text-destructive">
          {error}
        </span>
      )}
    </span>
  );
}
