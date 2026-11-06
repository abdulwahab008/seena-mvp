'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm, Controller } from 'react-hook-form';
import { toast } from 'sonner';
import { inviteStaff } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { STAFF_ROLE_OPTIONS as ROLE_OPTIONS, type StaffRole as RoleValue } from '@/lib/staff-roles';
import type { InviteDelivery } from '@/lib/staff-invite';
import { InviteLinkPanel } from './invite-link-panel';
type FormValues = { email: string; role: RoleValue | '' };

export function InviteForm({ campusId }: { campusId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [last, setLast] = useState<{ email: string; delivery: InviteDelivery } | null>(null);
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
        toast.success(result.delivery?.emailed ? `Invitation emailed to ${values.email}.` : `Invitation created for ${values.email}.`);
        setLast(result.delivery ? { email: values.email, delivery: result.delivery } : null);
        reset();
        router.refresh();
      }
    });
  });

  return (
    <div className="space-y-3">
    <form onSubmit={onSubmit} className="grid grid-cols-1 items-end gap-2 sm:grid-cols-[2fr_2fr_auto]" noValidate>
      <div className="space-y-1">
        <Label htmlFor="invite-email">Email</Label>
        <Input id="invite-email" type="email" placeholder="teacher@school.edu.pk" {...register('email', { required: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="invite-role">Role</Label>
        <Controller
          control={control}
          name="role"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger id="invite-role" data-testid="invite-role-trigger">
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
        {pending ? 'Creating…' : 'Send invite'}
      </Button>
    </form>
    {last && <InviteLinkPanel email={last.email} delivery={last.delivery} />}
    </div>
  );
}
