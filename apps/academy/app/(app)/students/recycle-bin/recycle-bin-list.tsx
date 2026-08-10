'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { restoreStudent } from '../actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type RecycleBinRow = {
  id: string;
  nameEn: string;
  grNumber: string;
  deletedAt: string;
  deletedByName: string;
};

function RestoreControl({ studentId, studentName }: { studentId: string; studentName: string }) {
  const [pending, startTransition] = useTransition();

  const onRestore = () => {
    startTransition(async () => {
      const result = await restoreStudent(studentId);
      if (result.error) toast.error(result.error);
      else toast.success(`${studentName} restored.`);
    });
  };

  return (
    <Button type="button" size="sm" onClick={onRestore} disabled={pending} data-testid={`restore-student-${studentId}`}>
      {pending ? 'Restoring…' : 'Restore'}
    </Button>
  );
}

export function RecycleBinList({ students }: { students: RecycleBinRow[] }) {
  if (students.length === 0) {
    return <p className="text-sm text-muted-foreground">The Recycle Bin is empty.</p>;
  }

  return (
    <div className="space-y-2">
      {students.map((s) => (
        <Card key={s.id} data-testid={`recycle-bin-row-${s.grNumber}`}>
          <CardContent className="flex items-center justify-between p-4">
            <div>
              <p className="font-medium">
                {s.nameEn} <span className="text-muted-foreground">({s.grNumber})</span>
              </p>
              <p className="text-sm text-muted-foreground">
                Deleted {new Date(s.deletedAt).toLocaleString()} by {s.deletedByName}
              </p>
            </div>
            <RestoreControl studentId={s.id} studentName={s.nameEn} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
