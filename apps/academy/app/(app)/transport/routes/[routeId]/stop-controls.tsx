'use client';

import { useState } from 'react';
import { ActionButton } from '@/components/spec-form';
import { moveStop, removeStop } from '../actions';

/** Up, down, jump-to-position and remove for one stop of a route. */
export function StopControls({ routeId, stopId, seq, count }: { routeId: string; stopId: string; seq: number; count: number }) {
  const [target, setTarget] = useState(String(seq));
  return (
    <span className="flex flex-wrap items-center gap-1">
      {seq > 1 && <ActionButton label="Up" testId={`stop-up-${seq}`} action={() => moveStop(routeId, stopId, seq - 1)} />}
      {seq < count && <ActionButton label="Down" testId={`stop-down-${seq}`} action={() => moveStop(routeId, stopId, seq + 1)} />}
      <input
        type="number"
        min={1}
        max={count}
        value={target}
        onChange={(e) => setTarget(e.target.value)}
        aria-label={`Position for stop ${seq}`}
        className="h-9 w-16 rounded-md border bg-background px-2 text-sm"
      />
      <ActionButton label="Move" testId={`stop-move-${seq}`} action={() => moveStop(routeId, stopId, Number(target))} />
      <ActionButton label="Remove" variant="ghost" confirm="Remove this stop?" action={() => removeStop(routeId, stopId)} />
    </span>
  );
}
