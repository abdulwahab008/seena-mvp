'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { clearanceCheckAction, requestOtpAction } from './actions';

export function RequestOtpButton({ custodyId }: { custodyId: string }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="inline-flex items-center gap-2">
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="request-otp"
        onClick={() =>
          startTransition(async () => {
            const r = await requestOtpAction(custodyId);
            setError(r.error);
            if (!r.error) toast.success('A code has been sent to the custodian.');
          })
        }
      >
        Send code
      </Button>
      {error && (
        <span role="alert" className="text-xs text-destructive">
          {error}
        </span>
      )}
    </span>
  );
}

export function ClearanceChecker({ staff }: { staff: { id: string; label: string }[] }) {
  const [pending, startTransition] = useTransition();
  const [staffId, setStaffId] = useState('');
  const [result, setResult] = useState<{ error: string | null; cleared?: boolean; assets?: { tag_no: string; name: string }[] } | null>(null);
  return (
    <div className="space-y-3" data-testid="clearance-checker">
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <Label htmlFor="clearance-staff">Staff member</Label>
          <select id="clearance-staff" value={staffId} onChange={(e) => setStaffId(e.target.value)} className="h-9 rounded-md border bg-background px-2 text-sm">
            <option value="">Choose</option>
            {staff.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </div>
        <Button type="button" disabled={pending || !staffId} data-testid="clearance-check" onClick={() => startTransition(async () => setResult(await clearanceCheckAction(staffId)))}>
          Check exit clearance
        </Button>
      </div>
      {result?.error && (
        <p role="alert" className="text-sm text-destructive">
          {result.error}
        </p>
      )}
      {result && !result.error && result.cleared && (
        <p className="text-sm text-success" data-testid="clearance-ok">
          Cleared: no assets are outstanding.
        </p>
      )}
      {result && !result.error && !result.cleared && (
        <div className="text-sm" data-testid="clearance-blocked">
          <p className="font-medium text-destructive">Blocked: {result.assets?.length} asset(s) still with this person.</p>
          <ul className="list-disc pl-5">
            {result.assets?.map((a) => (
              <li key={a.tag_no}>
                {a.tag_no} · {a.name}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
