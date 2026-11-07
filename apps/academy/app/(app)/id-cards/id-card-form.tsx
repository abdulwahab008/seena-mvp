'use client';

import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const schema = z.object({
  kind: z.enum(['student', 'staff']),
  sectionId: z.string(),
  validUntil: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
});
type Values = z.infer<typeof schema>;

const SELECT =
  'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary';

export function IdCardForm({ campusId, sections }: { campusId: string; sections: { id: string; label: string }[] }) {
  const nextYear = `${new Date().getFullYear() + 1}-03-31`;
  const { register, handleSubmit, watch, formState: { errors } } = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: { kind: 'student', sectionId: '', validUntil: nextYear },
  });
  const kind = watch('kind');

  const onSubmit = handleSubmit((v) => {
    const params = new URLSearchParams({ kind: v.kind, campusId, validUntil: v.validUntil });
    if (v.kind === 'student' && v.sectionId) params.set('sectionId', v.sectionId);
    window.open(`/api/id-cards?${params}`, '_blank', 'noopener');
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">Cards for</legend>
        <div className="flex gap-4 text-sm">
          <label className="flex items-center gap-2">
            <input type="radio" value="student" {...register('kind')} /> Students
          </label>
          <label className="flex items-center gap-2">
            <input type="radio" value="staff" {...register('kind')} /> Staff
          </label>
        </div>
      </fieldset>
      {kind === 'student' && (
        <div className="space-y-1">
          <Label htmlFor="card-section">Class and section</Label>
          <select id="card-section" className={SELECT} {...register('sectionId')}>
            <option value="">Every class on this campus</option>
            {sections.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </div>
      )}
      <div className="space-y-1">
        <Label htmlFor="card-valid">Valid until</Label>
        <Input id="card-valid" type="date" {...register('validUntil')} />
        {errors.validUntil && <p className="text-sm text-destructive">{errors.validUntil.message}</p>}
      </div>
      <Button type="submit">Print cards</Button>
      <p className="text-xs text-muted-foreground">Opens a PDF in a new tab. Print it on card stock and cut along the borders.</p>
    </form>
  );
}
