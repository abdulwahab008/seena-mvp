'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm, Controller } from 'react-hook-form';
import { toast } from 'sonner';
import { inviteStaff } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export const ROLE_OPTIONS = [
  { value: 'principal', label: 'Principal' },
  { value: 'admissions_officer', label: 'Admissions Officer' },
  { value: 'accountant', label: 'Accountant' },
  { value: 'exam_controller', label: 'Exam Controller' },
  { value: 'subject_teacher', label: 'Teacher (Subject Teacher)' },
  { value: 'hr_manager', label: 'HR Manager' },
] as const;

type RoleValue = (typeof ROLE_OPTIONS)[number]['value'];
type FormValues = { email: string; role: RoleValue | '' };

export function InviteForm({ campusId }: { campusId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, control, reset } = useForm<FormValues>({
    defaultValues: { email: '', role: '' },
  });

  const onSubmit = handleSubmit((values) => {
    if (!values.role) {
      toast.error('Choose a role.');
      return;
    }
    const fd = new FormData();
    fd.set('email', values.email);
    fd.set('role', values.role);
    startTransition(async () => {
      const result = await inviteStaff(campusId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`Invitation sent to ${values.email}.`);
        reset();
        router.refresh();
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-[2fr_2fr_auto] items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor="invite-email">Email</Label>
        <Input id="invite-email" type="email" placeholder="teacher@school.edu.pk" {...register('email', { required: true })} />
      </div>
      <div className="space-y-1">
        <Label>Role</Label>
        <Controller
          control={control}
          name="role"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="invite-role-trigger">
                <SelectValue placeholder="Select a role" />
              </SelectTrigger>
              <SelectContent>
                {ROLE_OPTIONS.map((opt) => (
                  <SelectItem key={opt.value} value={opt.value}>
                    {opt.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <Button type="submit" disabled={pending}>
        {pending ? 'Sending…' : 'Send invite'}
      </Button>
    </form>
  );
}
