'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { linkGuardianToStudent } from '../actions';
import { linkGuardianSchema, GUARDIAN_RELATIONSHIPS, type LinkGuardianInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export function GuardianForm({ studentId }: { studentId: string }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<LinkGuardianInput>({
    resolver: zodResolver(linkGuardianSchema),
    defaultValues: { relationship: 'father', isPrimary: false, receivesBilling: false, mayCollectChild: true },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('nameEn', values.nameEn);
    if (values.cnic) fd.set('cnic', values.cnic);
    if (values.phone) fd.set('phone', values.phone);
    fd.set('relationship', values.relationship);
    if (values.isPrimary) fd.set('isPrimary', 'on');
    if (values.receivesBilling) fd.set('receivesBilling', 'on');
    if (values.mayCollectChild) fd.set('mayCollectChild', 'on');

    startTransition(async () => {
      const result = await linkGuardianToStudent(studentId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${values.nameEn} linked.`);
        reset({ relationship: 'father', isPrimary: false, receivesBilling: false, mayCollectChild: true });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="nameEn">Name</Label>
        <Input id="nameEn" {...register('nameEn')} />
        {errors.nameEn && <p className="text-xs text-destructive">{errors.nameEn.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="cnic">CNIC (optional)</Label>
        <Input id="cnic" placeholder="3520212345678" {...register('cnic')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="phone">Phone (optional)</Label>
        <Input id="phone" {...register('phone')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="relationship">Relationship</Label>
        <Controller
          control={control}
          name="relationship"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="guardian-relationship-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {GUARDIAN_RELATIONSHIPS.map((r) => (
                  <SelectItem key={r} value={r}>
                    {r.replace(/_/g, ' ')}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>

      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" {...register('isPrimary')} />
        Primary
      </label>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" {...register('receivesBilling')} />
        Receives fee notices
      </label>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" {...register('mayCollectChild')} />
        May collect child
      </label>

      <Button type="submit" disabled={pending} className="col-span-full w-fit">
        {pending ? 'Saving…' : 'Link guardian'}
      </Button>
    </form>
  );
}
