'use client';

import { useActionState, useEffect, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { addComplianceDocument, renewDocument, runExpiryCheck, type ActionState } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const initial: ActionState = { error: null };

export function AddDocumentForm({ staff, types }: { staff: { userId: string; name: string }[]; types: { code: string; label: string }[] }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(addComplianceDocument, initial);
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
    }
  }, [state, router]);
  return (
    <form action={action} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4" data-testid="add-document-form">
      <div className="space-y-1">
        <Label htmlFor="staffUserId">Staff member</Label>
        <select id="staffUserId" name="staffUserId" required className="h-9 w-full rounded-md border bg-background px-2 text-sm">
          <option value="">Choose…</option>
          {staff.map((s) => (
            <option key={s.userId} value={s.userId}>
              {s.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="documentType">Document</Label>
        <select id="documentType" name="documentType" required className="h-9 w-full rounded-md border bg-background px-2 text-sm">
          {types.map((t) => (
            <option key={t.code} value={t.code}>
              {t.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="expiresOn">Expires on</Label>
        <Input id="expiresOn" name="expiresOn" type="date" required />
      </div>
      <div className="space-y-1">
        <Label htmlFor="document">Scan (optional)</Label>
        <Input id="document" name="document" type="file" accept="application/pdf,image/jpeg,image/png" />
      </div>
      {state.error && (
        <p role="alert" className="text-sm text-destructive sm:col-span-2 lg:col-span-4" data-testid="document-error">
          {state.error}
        </p>
      )}
      <div className="sm:col-span-2 lg:col-span-4">
        <Button type="submit" disabled={pending} data-testid="save-document">
          Record document
        </Button>
      </div>
    </form>
  );
}

export function RenewForm({ documentId }: { documentId: string }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(renewDocument, initial);
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
    }
  }, [state, router]);
  return (
    <form action={action} className="flex items-center gap-2">
      <input type="hidden" name="documentId" value={documentId} />
      <Input name="expiresOn" type="date" required aria-label="New expiry date" className="h-8 w-40" />
      <Button type="submit" size="sm" variant="outline" disabled={pending} data-testid="renew-document">
        Renew
      </Button>
      {state.error && <span role="alert" className="text-xs text-destructive">{state.error}</span>}
    </form>
  );
}

export function RunCheckButton() {
  const router = useRouter();
  const [pending, start] = useTransition();
  return (
    <Button
      variant="outline"
      disabled={pending}
      data-testid="run-expiry-check"
      onClick={() =>
        start(async () => {
          const r = await runExpiryCheck();
          if (r.error) toast.error(r.error);
          else toast.success(r.message ?? 'Done.');
          router.refresh();
        })
      }
    >
      Run expiry check now
    </Button>
  );
}
