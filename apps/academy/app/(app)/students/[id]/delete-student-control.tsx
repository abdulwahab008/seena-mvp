'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { deleteStudent } from '../actions';
import { Button } from '@/components/ui/button';

export function DeleteStudentControl({ studentId, studentName }: { studentId: string; studentName: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [confirming, setConfirming] = useState(false);

  if (!confirming) {
    return (
      <Button type="button" size="sm" variant="destructive" onClick={() => setConfirming(true)} data-testid="delete-student-button">
        Delete
      </Button>
    );
  }

  const onConfirm = () => {
    startTransition(async () => {
      const result = await deleteStudent(studentId);
      if (result.error) {
        toast.error(result.error);
        setConfirming(false);
        return;
      }
      toast.success(`${studentName} moved to the Recycle Bin.`);
      router.push('/students');
    });
  };

  return (
    <div className="flex items-center gap-2">
      <span className="text-sm text-muted-foreground">Delete {studentName}?</span>
      <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={onConfirm} data-testid="confirm-delete-student">
        {pending ? 'Deleting…' : 'Confirm'}
      </Button>
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => setConfirming(false)}>
        Cancel
      </Button>
    </div>
  );
}
