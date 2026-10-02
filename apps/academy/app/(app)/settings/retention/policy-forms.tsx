'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { savePolicy, startDryRun } from './actions';
import { Button } from '@/components/ui/button';

export function PolicyRow({ category, years, canEdit }: { category: 'student_identity' | 'student_name_gr' | 'guardian_contact' | 'fee_ledger'; years: number; canEdit: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [value, setValue] = useState(String(years));
  const [error, setError] = useState<string | null>(null);
  if (!canEdit) return <span>{years} years</span>;
  return (
    <span className="flex items-center gap-2">
      <input aria-label={`${category} years`} type="number" min={1} max={50} value={value} onChange={(e) => setValue(e.target.value)} className="h-9 w-20 rounded-md border bg-background px-2" />
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid={`save-${category}`}
        onClick={() =>
          startTransition(async () => {
            const r = await savePolicy({ category, years: Number(value) });
            setError(r.error);
            if (!r.error) {
              toast.success('Retention updated.');
              router.refresh();
            }
          })
        }
      >
        Save
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}

export function DryRunButton() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="space-y-1">
      <Button
        type="button"
        disabled={pending}
        data-testid="dry-run"
        onClick={() =>
          startTransition(async () => {
            const r = await startDryRun();
            setError(r.error);
            if (!r.error) router.refresh();
          })
        }
      >
        {pending ? 'Listing…' : 'Dry run (change nothing)'}
      </Button>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
    </div>
  );
}
