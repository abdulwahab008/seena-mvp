'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { autofillSection, copySection } from './autofill-actions';

const SELECT = 'h-9 rounded-md border bg-background px-2 text-sm';
const schema = z.object({ fromSectionId: z.string().min(1, 'Choose a section') });

export function AutofillControls({ versionId, sectionId, otherSections }: { versionId: string; sectionId: string; otherSections: { id: string; label: string }[] }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: { fromSectionId: '' } });
  const fill = () =>
    startTransition(async () => {
      const r = await autofillSection(versionId, sectionId);
      if (r.error) return void toast.error(r.error);
      const short = (r.unplaced ?? []).map((u) => `${u.subject} (${u.missing})`).join(', ');
      toast.success(`Placed ${r.placed} ${r.placed === 1 ? 'period' : 'periods'}.${short ? ` Could not place: ${short}.` : ''}`);
    });
  const copy = handleSubmit((v) =>
    startTransition(async () => {
      const r = await copySection(versionId, v.fromSectionId, sectionId);
      if (r.error) return void toast.error(r.error);
      toast.success(`Copied ${r.copied} ${r.copied === 1 ? 'period' : 'periods'}${r.skipped ? `; ${r.skipped} skipped where a teacher or room was already busy` : ''}.`);
    }),
  );
  return (
    <div className="flex flex-wrap items-end gap-3 rounded-md border p-3" data-testid="autofill-controls">
      <Button variant="outline" onClick={fill} disabled={pending}>
        Fill empty periods automatically
      </Button>
      {otherSections.length > 0 && (
        <form onSubmit={copy} className="flex items-end gap-2" noValidate>
          <div className="space-y-1">
            <Label htmlFor="tt-copy-from">Copy from section</Label>
            <select id="tt-copy-from" className={SELECT} {...register('fromSectionId')}>
              <option value="">Choose…</option>
              {otherSections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
          </div>
          <Button type="submit" variant="outline" disabled={pending}>
            Copy
          </Button>
        </form>
      )}
      <p className="w-full text-xs text-muted-foreground">Only empty periods are filled; nothing already placed changes. Teacher and room clashes are still refused.</p>
    </div>
  );
}
