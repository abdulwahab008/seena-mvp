'use client';

import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { compressImage } from '@/lib/uploads/compress-image';
import { deleteHomework, removeHomeworkAttachment, uploadHomeworkAttachment } from './attachment-actions';
import { Button } from '@/components/ui/button';

const MAX_BYTES = 5 * 1024 * 1024;
const MAX_FILES = 5;

export type AttachmentRow = { id: string; name: string; sizeBytes: number };

export function AttachmentPanel({ homeworkId, attachments, canEdit }: { homeworkId: string; attachments: AttachmentRow[]; canEdit: boolean }) {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const onPick = (e: React.ChangeEvent<HTMLInputElement>) => {
    const picked = e.target.files?.[0];
    if (!picked) return;
    setError(null);
    startTransition(async () => {
      const file = await compressImage(picked);
      if (file.size > MAX_BYTES) setError('File exceeds 5 MB limit');
      else if (attachments.length >= MAX_FILES) setError('Maximum 5 attachments per assignment');
      else {
        const fd = new FormData();
        fd.set('homeworkId', homeworkId);
        fd.set('file', file);
        const r = await uploadHomeworkAttachment(fd);
        setError(r.error);
        if (!r.error) {
          toast.success('File attached.');
          router.refresh();
        }
      }
      if (inputRef.current) inputRef.current.value = '';
    });
  };

  const run = (fn: () => Promise<{ error: string | null }>, done: string) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) {
        toast.success(done);
        router.refresh();
      }
    });

  return (
    <div className="mt-3 space-y-2 text-sm" data-testid="homework-attachments">
      {attachments.map((a) => (
        <div key={a.id} className="flex items-center justify-between gap-2" data-testid="homework-attachment">
          <a href={`/api/homework-attachments/${a.id}`} className="underline-offset-2 hover:underline" target="_blank" rel="noreferrer">
            {a.name}
          </a>
          <span className="text-muted-foreground">{(a.sizeBytes / 1024 / 1024).toFixed(1)} MB</span>
          {canEdit && (
            <Button size="sm" variant="ghost" disabled={pending} onClick={() => run(() => removeHomeworkAttachment(a.id), 'Attachment removed.')}>
              Remove
            </Button>
          )}
        </div>
      ))}
      {canEdit && (
        <div className="flex flex-wrap items-center gap-2">
          <input ref={inputRef} type="file" accept="application/pdf,image/jpeg,image/png,image/webp" aria-label="Attach a file" onChange={onPick} disabled={pending} className="text-xs" />
          <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => deleteHomework(homeworkId), 'Homework deleted.')} data-testid="homework-delete">
            Delete assignment
          </Button>
        </div>
      )}
      {error && <p role="alert" className="text-xs text-destructive" data-testid="attachment-error">{error}</p>}
    </div>
  );
}
