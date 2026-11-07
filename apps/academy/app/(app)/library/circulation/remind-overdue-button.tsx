'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { remindOverdue } from './overdue-actions';

export function RemindOverdueButton({ campusId }: { campusId: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="outline"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await remindOverdue(campusId);
          if (r.error) return void toast.error(r.error);
          toast.success(`Sent ${r.queued} overdue ${r.queued === 1 ? 'reminder' : 'reminders'} to parents${r.noPhone ? `; ${r.noPhone} without a phone` : ''}.`);
        })
      }
    >
      Remind parents of overdue books
    </Button>
  );
}
