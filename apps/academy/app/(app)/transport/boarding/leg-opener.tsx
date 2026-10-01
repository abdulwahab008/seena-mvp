'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { openLeg } from './actions';

const CONTROL = 'h-9 rounded-md border bg-background px-2 text-sm';

export function LegOpener({ routes }: { routes: { id: string; label: string }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [routeId, setRouteId] = useState(routes[0]?.id ?? '');
  const [legType, setLegType] = useState<'pickup' | 'drop'>('pickup');
  return (
    <div className="space-y-2" data-testid="leg-opener">
      <div className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Route</span>
          <select value={routeId} onChange={(e) => setRouteId(e.target.value)} className={CONTROL} aria-label="Route">
            {routes.map((r) => (
              <option key={r.id} value={r.id}>
                {r.label}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Trip</span>
          <select value={legType} onChange={(e) => setLegType(e.target.value as 'pickup' | 'drop')} className={CONTROL} aria-label="Trip">
            <option value="pickup">Pickup (to school)</option>
            <option value="drop">Drop (home)</option>
          </select>
        </label>
        <Button
          type="button"
          size="sm"
          disabled={pending || !routeId}
          data-testid="open-leg"
          onClick={() =>
            startTransition(async () => {
              const r = await openLeg({ routeId, legType });
              setError(r.error);
              if (!r.error && r.legId) router.push(`/transport/boarding?leg=${r.legId}`);
            })
          }
        >
          Open today&apos;s trip
        </Button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
    </div>
  );
}
