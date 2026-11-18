'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { readmitStudent } from '../actions';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { Textarea } from '@/components/ui/textarea';

type Section = { id: string; label: string };

export function ReadmitStudentControl({
  studentId,
  studentName,
  sections,
  flagged,
  defaultSectionId,
}: {
  studentId: string;
  studentName: string;
  sections: Section[];
  flagged: boolean;
  defaultSectionId: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  return (
    <>
      <Button variant="outline" onClick={() => setOpen(true)} data-testid="readmit-student">
        Readmit
      </Button>
      {open && (
        <Modal open={open} onClose={() => setOpen(false)} title={`Readmit ${studentName}`} description="The student becomes active again from today in the section you choose.">
          <form
            className="space-y-3"
            onSubmit={(e) => {
              e.preventDefault();
              const fd = new FormData(e.currentTarget);
              startTransition(async () => {
                const r = await readmitStudent(studentId, fd);
                if (r.error) setError(r.error);
                else {
                  toast.success(`${studentName} has been readmitted.`);
                  setOpen(false);
                  router.refresh();
                }
              });
            }}
          >
            <div className="space-y-1">
              <Label htmlFor="readmit-section">Section</Label>
              <select id="readmit-section" name="sectionId" required defaultValue={sections.some((s) => s.id === defaultSectionId) ? defaultSectionId : ''} className="h-10 w-full rounded-md border bg-background px-3 text-sm">
                <option value="" disabled>
                  Choose a section
                </option>
                {sections.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.label}
                  </option>
                ))}
              </select>
            </div>
            {flagged && (
              <div className="space-y-1">
                <Label htmlFor="readmit-reason">Reason for overriding &quot;no readmission&quot;</Label>
                <Textarea id="readmit-reason" name="overrideReason" rows={2} maxLength={500} required />
                <p className="text-xs text-muted-foreground">This student was flagged not to be readmitted. Only the owner can override it.</p>
              </div>
            )}
            {error && (
              <p role="alert" className="text-sm text-destructive">
                {error}
              </p>
            )}
            <div className="flex justify-end gap-2">
              <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={pending} data-testid="confirm-readmit">
                {pending ? 'Readmitting…' : 'Readmit student'}
              </Button>
            </div>
          </form>
        </Modal>
      )}
    </>
  );
}
