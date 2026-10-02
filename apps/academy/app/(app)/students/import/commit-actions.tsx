'use client';

import { useRouter } from 'next/navigation';
import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { commitStudentImport, undoStudentImport } from './actions';

export function CommitImportButton({ batchId, okRows }: { batchId: string; okRows: number }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const onCommit = () => {
    setError(null);
    startTransition(async () => {
      const result = await commitStudentImport(batchId);
      if (result.error) {
        setError(result.error);
        return;
      }
      if (!result.ok) {
        // Not an error path: the batch rolled back cleanly and the page
        // re-renders showing which row stopped it.
        toast.error(`Import stopped at row ${result.failedRowNo} — nothing was imported.`);
        router.refresh();
        return;
      }
      toast.success(`Imported ${result.committedRows} student${result.committedRows === 1 ? '' : 's'}.`);
      router.refresh();
    });
  };

  return (
    <div className="space-y-2">
      <Button onClick={onCommit} disabled={pending || okRows === 0} data-testid="import-commit">
        {pending ? 'Importing…' : `Import ${okRows} row${okRows === 1 ? '' : 's'}`}
      </Button>
      {error && (
        <p className="text-sm text-destructive" data-testid="import-commit-error">
          {error}
        </p>
      )}
    </div>
  );
}

export function UndoImportButton({ batchId }: { batchId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const onUndo = () => {
    setError(null);
    startTransition(async () => {
      const result = await undoStudentImport(batchId);
      if (result.error) {
        setError(result.error);
        return;
      }
      toast.success('Import undone — every student it created has been removed.');
      router.refresh();
    });
  };

  return (
    <div className="space-y-2">
      <Button variant="outline" onClick={onUndo} disabled={pending} data-testid="import-undo">
        {pending ? 'Undoing…' : 'Undo this import'}
      </Button>
      {error && (
        <p className="text-sm text-destructive" data-testid="import-undo-error">
          {error}
        </p>
      )}
    </div>
  );
}
