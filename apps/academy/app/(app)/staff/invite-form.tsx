'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { toast } from 'sonner';
import { inviteStaff } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

const ROLES = [
  'principal', 'vice_principal', 'admissions_officer', 'accountant', 'exam_controller',
  'head_of_department', 'class_teacher', 'subject_teacher', 'hr_manager', 'librarian',
  'transport_manager', 'receptionist',
] as const;

type FormValues = { email: string; role: (typeof ROLES)[number] | '' };

export function InviteForm({ campusId }: { campusId: string }) {
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
                {ROLES.map((r) => (
                  <SelectItem key={r} value={r}>
                    {r.replace(/_/g, ' ')}
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
