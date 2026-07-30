'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createStudent } from './actions';
import { createStudentSchema, type CreateStudentInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type Campus = { id: string; code: string; name: string };

export function NewStudentForm({ campuses }: { campuses: Campus[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    formState: { errors },
  } = useForm<CreateStudentInput>({
    resolver: zodResolver(createStudentSchema),
    defaultValues: { campusId: campuses[0]?.id ?? '', gender: 'male' },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('campusId', values.campusId);
    fd.set('nameEn', values.nameEn);
    if (values.nameUr) fd.set('nameUr', values.nameUr);
    fd.set('dob', values.dob);
    fd.set('gender', values.gender);
    if (values.fatherNameEn) fd.set('fatherNameEn', values.fatherNameEn);
    if (values.fatherNameUr) fd.set('fatherNameUr', values.fatherNameUr);
    if (values.bFormNo) fd.set('bFormNo', values.bFormNo);

    startTransition(async () => {
      const result = await createStudent({ error: null, studentId: null }, fd);
      if (result.error || !result.studentId) {
        toast.error(result.error ?? 'Could not save the student.');
        return;
      }
      toast.success(`${values.nameEn} admitted.`);
      router.push(`/students/${result.studentId}`);
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="campusId">Campus</Label>
        <Controller
          control={control}
          name="campusId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="student-campus-trigger">
                <SelectValue placeholder="Select a campus" />
              </SelectTrigger>
              <SelectContent>
                {campuses.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="nameEn">Name</Label>
        <Input id="nameEn" {...register('nameEn')} />
        {errors.nameEn && <p className="text-xs text-destructive">{errors.nameEn.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="nameUr">Name (Urdu)</Label>
        <Input id="nameUr" {...register('nameUr')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="dob">Date of birth</Label>
        <Input id="dob" type="date" {...register('dob')} />
        {errors.dob && <p className="text-xs text-destructive">{errors.dob.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="gender">Gender</Label>
        <Controller
          control={control}
          name="gender"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="student-gender-trigger">
                <SelectValue placeholder="Select" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="male">Male</SelectItem>
                <SelectItem value="female">Female</SelectItem>
                <SelectItem value="other">Other</SelectItem>
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="fatherNameEn">Father's name</Label>
        <Input id="fatherNameEn" {...register('fatherNameEn')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="bFormNo">B-Form number (optional)</Label>
        <Input id="bFormNo" placeholder="3520212345678" {...register('bFormNo')} />
      </div>

      <Button type="submit" disabled={pending} className="col-span-full w-fit">
        {pending ? 'Saving…' : 'Admit student'}
      </Button>
    </form>
  );
}
