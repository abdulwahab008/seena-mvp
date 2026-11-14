'use client';

import { useRef, useTransition } from 'react';
import { Camera } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { compressImage } from '@/lib/uploads/compress-image';
import { removePhoto, uploadPhoto } from '@/lib/photos/actions';

/** A profile photo: the picture (or initials) and, for those who may, change and remove buttons. */
export function PhotoUpload({
  kind,
  id,
  name,
  url,
  canEdit,
}: {
  kind: 'student' | 'staff';
  id: string;
  name: string;
  url: string | null;
  canEdit: boolean;
}) {
  const input = useRef<HTMLInputElement>(null);
  const [pending, startTransition] = useTransition();
  const initials = name
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? '')
    .join('');

  const onPick = (file: File | undefined) => {
    if (!file) return;
    startTransition(async () => {
      // ID-card size: small enough that a whole class's cards fit in one PDF.
      const small = await compressImage(file, 480, 0);
      const fd = new FormData();
      fd.set('photo', small);
      const result = await uploadPhoto(kind, id, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Photo saved.');
      if (input.current) input.current.value = '';
    });
  };

  const onRemove = () =>
    startTransition(async () => {
      const result = await removePhoto(kind, id);
      if (result.error) toast.error(result.error);
      else toast.success('Photo removed.');
    });

  return (
    <div className="flex shrink-0 flex-col items-center gap-1">
      {url ? (
        // A plain img: the signed URL is short-lived, and next/image would cache it past expiry.
        <img src={url} alt={`Photo of ${name}`} className="h-20 w-20 rounded-full border object-cover" data-testid="profile-photo" />
      ) : (
        <div className="flex h-20 w-20 items-center justify-center rounded-full bg-primary-muted text-xl font-semibold text-primary" aria-hidden>
          {initials}
        </div>
      )}
      {canEdit && (
        <div className="flex gap-1">
          <input
            ref={input}
            type="file"
            accept="image/jpeg,image/png,image/webp"
            className="hidden"
            aria-label={`Photo of ${name}`}
            onChange={(e) => onPick(e.target.files?.[0])}
          />
          <Button type="button" size="sm" variant="ghost" className="h-7 px-2 text-xs" disabled={pending} onClick={() => input.current?.click()}>
            <Camera className="mr-1 h-3.5 w-3.5" aria-hidden />
            {pending ? 'Saving…' : url ? 'Change' : 'Upload photo'}
          </Button>
          {url && (
            <Button type="button" size="sm" variant="ghost" className="h-7 px-2 text-xs text-destructive" disabled={pending} onClick={onRemove}>
              Remove photo
            </Button>
          )}
        </div>
      )}
    </div>
  );
}
