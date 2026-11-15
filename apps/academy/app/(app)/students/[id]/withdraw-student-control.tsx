'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { withdrawStudent } from '../actions';
import { WITHDRAWAL_REASON_CODES, WITHDRAWAL_REASON_LABEL } from '@/lib/validation';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { Textarea } from '@/components/ui/textarea';

export function WithdrawStudentControl({ studentId, studentName }: { studentId: string; studentName: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const today = todayPk();

  return (
    <>
      <Button variant="outline" onClick={() => setOpen(true)} data-testid="withdraw-student">
        Withdraw
      </Button>
      {open && (
        <Modal
          open={open}
          onClose={() => setOpen(false)}
          title={`Withdraw ${studentName}`}
          description="The student leaves their class from this date and moves to the withdrawal register. Their fee record stays as it is."
        >
          <form
            className="space-y-3"
            onSubmit={(e) => {
              e.preventDefault();
              const fd = new FormData(e.currentTarget);
              startTransition(async () => {
                const r = await withdrawStudent(studentId, fd);
                if (r.error) setError(r.error);
                else {
                  toast.success(`${studentName} has been withdrawn.`);
                  setOpen(false);
                  router.refresh();
                }
              });
            }}
          >
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-1">
                <Label htmlFor="withdraw-date">Leaving date</Label>
                <Input id="withdraw-date" name="leavingDate" type="date" defaultValue={today} max={today} required />
              </div>
              <div className="space-y-1">
                <Label htmlFor="withdraw-reason">Reason</Label>
                <select id="withdraw-reason" name="reason" required defaultValue="" className="h-10 w-full rounded-md border bg-background px-3 text-sm">
                  <option value="" disabled>
                    Choose a reason
                  </option>
                  {WITHDRAWAL_REASON_CODES.map((code) => (
                    <option key={code} value={code}>
                      {WITHDRAWAL_REASON_LABEL[code]}
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <div className="space-y-1">
              <Label htmlFor="withdraw-note">Note (optional)</Label>
              <Textarea id="withdraw-note" name="note" rows={2} maxLength={500} />
            </div>
            {error && (
              <p role="alert" className="text-sm text-destructive">
                {error}
              </p>
            )}
            <div className="flex justify-end gap-2">
              <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" variant="destructive" disabled={pending} data-testid="confirm-withdraw">
                {pending ? 'Withdrawing…' : 'Withdraw student'}
              </Button>
            </div>
          </form>
        </Modal>
      )}
    </>
  );
}
