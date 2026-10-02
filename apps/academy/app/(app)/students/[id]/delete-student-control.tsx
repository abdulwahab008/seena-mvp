'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { deleteStudent } from '../actions';
import { Button } from '@/components/ui/button';
import { ConfirmDialog } from '@/components/ui/modal';

export function DeleteStudentControl({ studentId, studentName }: { studentId: string; studentName: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [confirming, setConfirming] = useState(false);

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
    <>
      <Button
        type="button"
        size="sm"
        variant="destructive"
        onClick={() => setConfirming(true)}
        data-testid="delete-student-button"
      >
        Delete
      </Button>

      <ConfirmDialog
        open={confirming}
        onClose={() => setConfirming(false)}
        onConfirm={onConfirm}
        title="Delete Student Record"
        description={`Are you sure you want to move ${studentName} to the Recycle Bin? The student, enrolment, and fee records can be restored later by an administrator.`}
        confirmLabel={pending ? 'Deleting…' : 'Delete Student'}
        confirmTestId="confirm-delete-student"
        destructive
        pending={pending}
      />
    </>
  );
}

