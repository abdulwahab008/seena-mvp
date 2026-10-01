'use client';

import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { requestTenantExport } from './actions';
import { Button } from '@/components/ui/button';

export function RequestExportButton({ busy }: { busy: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  // keeps the list fresh while an archive is being built
  useEffect(() => {
    if (!busy) return;
    const t = setInterval(() => router.refresh(), 4000);
    return () => clearInterval(t);
  }, [busy, router]);
  return (
    <div className="space-y-2">
      <Button
        type="button"
        disabled={pending || busy}
        data-testid="request-tenant-export"
        onClick={() =>
          startTransition(async () => {
            setError(null);
            const r = await requestTenantExport();
            if (r.error) setError(r.error);
            else {
              toast.success('Export started. You can leave this page; the file appears below when it is ready.');
              router.refresh();
            }
          })
        }
      >
        {busy ? 'Export in progress…' : pending ? 'Starting…' : 'Export all school data'}
      </Button>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="export-request-error">
          {error}
        </p>
      )}
    </div>
  );
}
