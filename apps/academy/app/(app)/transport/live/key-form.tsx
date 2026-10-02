'use client';

import { useState, useTransition } from 'react';
import { Button } from '@/components/ui/button';
import { createGpsKey } from './actions';

export function KeyForm() {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [key, setKey] = useState<string | null>(null);
  return (
    <form
      className="space-y-3"
      data-testid="gps-key-form"
      onSubmit={(e) => {
        e.preventDefault();
        const label = String(new FormData(e.currentTarget).get('label') ?? '');
        startTransition(async () => {
          const r = await createGpsKey({ label });
          setError(r.error);
          setKey(r.key ?? null);
        });
      }}
    >
      <label className="block space-y-1 text-sm">
        <span className="block text-muted-foreground">Key name (the tracker vendor)</span>
        <input name="label" className="h-9 w-full max-w-sm rounded-md border bg-background px-2 text-sm" />
      </label>
      <Button type="submit" size="sm" disabled={pending} data-testid="gps-key-form-submit">
        Create device key
      </Button>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      {key && (
        <div className="space-y-1 rounded-md border p-3 text-sm" data-testid="gps-key">
          <p className="font-medium">Copy this key now. It is shown once and cannot be recovered.</p>
          <code className="block break-all">{key}</code>
          <p className="text-muted-foreground">Send it as the x-device-key header to /api/webhooks/transport/gps.</p>
        </div>
      )}
    </form>
  );
}
