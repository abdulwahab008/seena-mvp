'use client';

import { useState, useTransition } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createAccount } from './actions';
import { newAccountSchema, type NewAccountInput } from './schema';
import { PASSWORD_RULES } from '@/lib/auth/password';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';

export type RoleOption = { value: string; label: string };
type Campus = { id: string; name: string };

function FieldError({ message }: { message?: string }) {
  return message ? <p className="text-sm text-destructive">{message}</p> : null;
}

export function NewAccountButton({ roles, campuses, schoolSlug }: { roles: readonly RoleOption[]; campuses: Campus[]; schoolSlug: string }) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const {
    register,
    control,
    handleSubmit,
    watch,
    reset,
    formState: { errors },
  } = useForm<NewAccountInput>({
    resolver: zodResolver(newAccountSchema),
    defaultValues: { loginType: 'username', campusIds: campuses.length === 1 ? [campuses[0]!.id] : [] },
  });
  const loginType = watch('loginType');
  const username = watch('username');
  const fieldErrors = errors as Partial<Record<'username' | 'email', { message?: string }>>;

  const onSubmit = handleSubmit((values) =>
    startTransition(async () => {
      const r = await createAccount(values);
      if (r.error) {
        toast.error(r.error);
        return;
      }
      toast.success(
        values.loginType === 'username'
          ? `Login created. ${values.fullName} signs in as ${values.username.toLowerCase()}@${schoolSlug}.`
          : `Login created for ${values.email}.`,
      );
      reset();
      setOpen(false);
    }),
  );

  return (
    <>
      <Button onClick={() => setOpen(true)} data-testid="new-account">
        New login
      </Button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="New login"
        description="They sign in with this temporary password and must choose their own at once."
        footer={
          <>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
              Cancel
            </Button>
            <Button type="submit" form="new-account-form" disabled={pending}>
              {pending ? 'Creating…' : 'Create login'}
            </Button>
          </>
        }
      >
        <form id="new-account-form" onSubmit={onSubmit} className="space-y-4" noValidate>
          <div className="space-y-1">
            <Label htmlFor="account-name">Full name</Label>
            <Input id="account-name" {...register('fullName')} />
            <FieldError message={errors.fullName?.message} />
          </div>

          <div className="space-y-1">
            <Label htmlFor="account-role">Role</Label>
            <select id="account-role" data-testid="account-role" defaultValue="" className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2" {...register('role')}>
              <option value="" disabled>
                Select a role
              </option>
              {roles.map((r) => (
                <option key={r.value} value={r.value}>
                  {r.label}
                </option>
              ))}
            </select>
            <FieldError message={errors.role?.message} />
          </div>

          <fieldset className="space-y-1">
            <legend className="text-sm font-medium">Campuses</legend>
            <Controller
              control={control}
              name="campusIds"
              render={({ field }) => (
                <div className="flex flex-wrap gap-4">
                  {campuses.map((c) => (
                    <span key={c.id} className="flex items-center gap-2 text-sm">
                      <Checkbox
                        id={`campus-${c.id}`}
                        checked={field.value.includes(c.id)}
                        onCheckedChange={(on) => field.onChange(on ? [...field.value, c.id] : field.value.filter((id) => id !== c.id))}
                      />
                      <label htmlFor={`campus-${c.id}`}>{c.name}</label>
                    </span>
                  ))}
                </div>
              )}
            />
            <FieldError message={errors.campusIds?.message} />
          </fieldset>

          <fieldset className="space-y-2">
            <legend className="text-sm font-medium">Sign-in with</legend>
            <div className="flex gap-4 text-sm">
              <label className="flex items-center gap-2">
                <input type="radio" value="username" {...register('loginType')} /> Username
              </label>
              <label className="flex items-center gap-2">
                <input type="radio" value="email" {...register('loginType')} /> Email
              </label>
            </div>
            {loginType === 'username' ? (
              <div className="space-y-1">
                <Label htmlFor="account-username">Username</Label>
                <Input id="account-username" autoComplete="off" placeholder="ahmed.t" {...register('username')} />
                <p className="text-xs text-muted-foreground">
                  Signs in as <span className="font-mono">{(username || 'username').toLowerCase()}@{schoolSlug}</span>
                </p>
                <FieldError message={fieldErrors.username?.message} />
              </div>
            ) : (
              <div className="space-y-1">
                <Label htmlFor="account-email">Email</Label>
                <Input id="account-email" type="email" {...register('email')} />
                <FieldError message={fieldErrors.email?.message} />
              </div>
            )}
          </fieldset>

          <div className="space-y-1">
            <Label htmlFor="account-password">Temporary password</Label>
            <Input id="account-password" type="text" autoComplete="off" {...register('password')} />
            <p className="text-xs text-muted-foreground">{PASSWORD_RULES.join('. ')}. Give it to them in person.</p>
            <FieldError message={errors.password?.message} />
          </div>
        </form>
      </Modal>
    </>
  );
}
