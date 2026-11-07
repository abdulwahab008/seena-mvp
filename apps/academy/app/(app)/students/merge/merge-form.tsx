'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { mergeStudents, previewMerge } from './actions';

const schema = z.object({ keepGr: z.string().trim().min(1, 'Enter the GR number to keep'), removeGr: z.string().trim().min(1, 'Enter the duplicate GR number') });
type Preview = { keep: string; remove: string; moves: { table: string; rows: number }[] };

export function MergeForm() {
  const [pending, startTransition] = useTransition();
  const [preview, setPreview] = useState<Preview | null>(null);
  const { register, handleSubmit, getValues, reset, formState: { errors } } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: { keepGr: '', removeGr: '' } });
  const onPreview = handleSubmit((v) =>
    startTransition(async () => {
      const r = await previewMerge(v);
      if (r.error || !r.pair) return void toast.error(r.error ?? 'Something went wrong.');
      setPreview({ keep: `${r.pair.keep.name} (${r.pair.keep.gr})`, remove: `${r.pair.remove.name} (${r.pair.remove.gr})`, moves: r.moves ?? [] });
    }),
  );
  const onMerge = () =>
    startTransition(async () => {
      const r = await mergeStudents(getValues());
      if (r.error) return void toast.error(r.error);
      toast.success('Students merged.');
      setPreview(null);
      reset();
    });
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Which records?</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <form onSubmit={onPreview} className="grid gap-3 sm:grid-cols-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="mg-keep">GR number to keep</Label>
            <Input id="mg-keep" {...register('keepGr', { onChange: () => setPreview(null) })} />
            {errors.keepGr && <p className="text-sm text-destructive">{errors.keepGr.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="mg-remove">Duplicate GR number</Label>
            <Input id="mg-remove" {...register('removeGr', { onChange: () => setPreview(null) })} />
            {errors.removeGr && <p className="text-sm text-destructive">{errors.removeGr.message}</p>}
          </div>
          <div className="flex items-end">
            <Button type="submit" variant="outline" disabled={pending}>
              Preview
            </Button>
          </div>
        </form>
        {preview && (
          <div className="space-y-3 rounded-md border p-3 text-sm" data-testid="merge-preview">
            <p>
              Keep <strong>{preview.keep}</strong>; move everything from <strong>{preview.remove}</strong>:
            </p>
            {preview.moves.length === 0 ? (
              <p className="text-muted-foreground">The duplicate has nothing attached; it will just go to the recycle bin.</p>
            ) : (
              <ul className="list-inside list-disc">
                {preview.moves.map((m) => (
                  <li key={m.table}>
                    {m.table}: {m.rows}
                  </li>
                ))}
              </ul>
            )}
            <Button variant="destructive" onClick={onMerge} disabled={pending}>
              Merge
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
