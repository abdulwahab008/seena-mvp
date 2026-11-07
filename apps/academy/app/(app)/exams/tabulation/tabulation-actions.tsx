'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Modal } from '@/components/ui/modal';
import { sendResultMessages } from './actions';

export function PrintButton() {
  return (
    <Button variant="outline" onClick={() => window.print()}>
      Print
    </Button>
  );
}

export function SendResultsButton({ termId, sectionId }: { termId: string; sectionId: string }) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const send = () =>
    startTransition(async () => {
      const r = await sendResultMessages(termId, sectionId);
      if (r.error) return void toast.error(r.error);
      toast.success(`Queued ${r.queued} result ${r.queued === 1 ? 'message' : 'messages'}${r.noPhone ? `; ${r.noPhone} without a parent's phone` : ''}.`);
      setOpen(false);
    });
  return (
    <>
      <Button onClick={() => setOpen(true)}>Send results by SMS</Button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Send this section's results?"
        description="Each family gets one SMS with total marks, percentage and position. Withheld results are not sent, and a family is never sent the same term twice."
        size="sm"
        footer={
          <>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
              Cancel
            </Button>
            <Button onClick={send} disabled={pending}>
              Send
            </Button>
          </>
        }
      />
    </>
  );
}
