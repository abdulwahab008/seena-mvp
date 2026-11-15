'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { completeFollowup } from '../enquiries/actions';
import { FOLLOWUP_OUTCOME_LABEL } from '@/lib/validation';
import { Button } from '@/components/ui/button';

export function CompleteFollowupControl({ followupId, enquiryNo }: { followupId: string; enquiryNo: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  if (!open) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)} data-testid={`complete-followup-${enquiryNo}`}>
        Mark done
      </Button>
    );
  }
  return (
    <form
      className="flex flex-wrap items-center gap-1"
      onSubmit={(e) => {
        e.preventDefault();
        const fd = new FormData(e.currentTarget);
        startTransition(async () => {
          const r = await completeFollowup(followupId, fd);
          if (r.error) toast.error(r.error);
          else {
            toast.success('Follow-up done.');
            router.refresh();
          }
        });
      }}
    >
      <select name="outcome" required defaultValue="" aria-label="What happened" className="h-9 rounded-md border bg-background px-2 text-sm">
        <option value="" disabled>
          What happened?
        </option>
        {Object.entries(FOLLOWUP_OUTCOME_LABEL).map(([v, label]) => (
          <option key={v} value={v}>
            {label}
          </option>
        ))}
      </select>
      <input name="note" maxLength={500} placeholder="Note" aria-label="Note" className="h-9 w-48 rounded-md border bg-background px-2 text-sm" />
      <Button type="submit" size="sm" disabled={pending}>
        {pending ? 'Saving…' : 'Save'}
      </Button>
      <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>
        Cancel
      </Button>
    </form>
  );
}
