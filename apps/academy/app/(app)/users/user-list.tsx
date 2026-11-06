'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { resetAccountPassword, setAccountActive, setAccountRole } from './actions';
import type { RoleOption } from './new-account-form';
import type { Database } from '@/lib/database.types';
import { passwordSchema } from '@/lib/auth/password';
import { formatDateTimePk } from '@/lib/dates';
import { roleLabel } from '@/lib/staff-roles';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { EmptyState } from '@/components/ui/empty-state';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

type Account = Database['public']['Functions']['list_user_accounts']['Returns'][number];

const KIND_LABEL: Record<string, string> = { staff: 'Staff', parent: 'Parent', student: 'Student' };

const passwordForm = z.object({ password: passwordSchema });
const roleForm = z.object({ role: z.string().min(1, 'Choose a role') });

function PasswordModal({ account, onClose }: { account: Account; onClose: () => void }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof passwordForm>>({ resolver: zodResolver(passwordForm) });
  const onSubmit = handleSubmit(({ password }) =>
    startTransition(async () => {
      const r = await resetAccountPassword(account.user_id, password);
      if (r.error) return void toast.error(r.error);
      toast.success(`Temporary password set. ${account.full_name} must change it at next sign-in.`);
      onClose();
    }),
  );
  return (
    <Modal
      open
      onClose={onClose}
      title={`Reset password for ${account.full_name}`}
      description="They will have to choose their own password when they next sign in."
      size="sm"
      footer={
        <>
          <Button variant="outline" onClick={onClose} disabled={pending}>Cancel</Button>
          <Button type="submit" form="reset-form" disabled={pending}>Set password</Button>
        </>
      }
    >
      <form id="reset-form" onSubmit={onSubmit} className="space-y-1" noValidate>
        <Label htmlFor="reset-password">Temporary password</Label>
        <Input id="reset-password" type="text" autoComplete="off" {...register('password')} />
        {errors.password && <p className="text-sm text-destructive">{errors.password.message}</p>}
      </form>
    </Modal>
  );
}

function RoleModal({ account, roles, onClose }: { account: Account; roles: readonly RoleOption[]; onClose: () => void }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof roleForm>>({
    resolver: zodResolver(roleForm),
    defaultValues: { role: account.app_role },
  });
  const onSubmit = handleSubmit(({ role }) =>
    startTransition(async () => {
      const r = await setAccountRole(account.user_id, role);
      if (r.error) return void toast.error(r.error);
      toast.success(`${account.full_name} is now ${roleLabel(role)}.`);
      onClose();
    }),
  );
  return (
    <Modal
      open
      onClose={onClose}
      title={`Change role for ${account.full_name}`}
      size="sm"
      footer={
        <>
          <Button variant="outline" onClick={onClose} disabled={pending}>Cancel</Button>
          <Button type="submit" form="role-form" disabled={pending}>Save role</Button>
        </>
      }
    >
      <form id="role-form" onSubmit={onSubmit} className="space-y-1" noValidate>
        <Label htmlFor="change-role">Role</Label>
        <select id="change-role" className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2" {...register('role')}>
          {roles.map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
        </select>
        {errors.role && <p className="text-sm text-destructive">{errors.role.message}</p>}
      </form>
    </Modal>
  );
}

export function UserList({ accounts, roles, currentUserId }: { accounts: Account[]; roles: readonly RoleOption[]; currentUserId: string }) {
  const [pending, startTransition] = useTransition();
  const [resetting, setResetting] = useState<Account | null>(null);
  const [changingRole, setChangingRole] = useState<Account | null>(null);

  if (accounts.length === 0) {
    return <EmptyState title="No logins yet" description="Create a login with the New login button." />;
  }

  const toggle = (a: Account) =>
    startTransition(async () => {
      const r = await setAccountActive(a.user_id, !a.active);
      if (r.error) return void toast.error(r.error);
      toast.success(`${a.full_name}'s login is ${a.active ? 'off' : 'on'}.`);
    });

  return (
    <>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Name</TableHead>
            <TableHead>Signs in as</TableHead>
            <TableHead>Role</TableHead>
            <TableHead>Campus</TableHead>
            <TableHead>Last sign-in</TableHead>
            <TableHead>Status</TableHead>
            <TableHead className="text-right">Actions</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {accounts.map((a) => {
            const self = a.user_id === currentUserId;
            return (
              <TableRow key={a.user_id} data-testid={`account-${a.login_id}`}>
                <TableCell className="font-medium">{a.full_name}</TableCell>
                <TableCell className="font-mono text-xs">{a.login_id}</TableCell>
                <TableCell>{a.kind === 'staff' ? roleLabel(a.app_role) : KIND_LABEL[a.kind]}</TableCell>
                <TableCell>{a.campuses.join(', ') || '—'}</TableCell>
                <TableCell>{a.last_sign_in_at ? formatDateTimePk(a.last_sign_in_at) : 'Never'}</TableCell>
                <TableCell>
                  <Badge variant={a.active ? 'success' : 'outline'} data-testid="account-status">{a.active ? 'Active' : 'Off'}</Badge>
                </TableCell>
                <TableCell className="text-right">
                  {!self && (
                    <div className="flex justify-end gap-1">
                      <Button variant="ghost" size="sm" onClick={() => setResetting(a)}>Reset password</Button>
                      {a.kind === 'staff' && (
                        <Button variant="ghost" size="sm" onClick={() => setChangingRole(a)}>Change role</Button>
                      )}
                      {a.kind !== 'parent' && (
                        <Button variant="ghost" size="sm" disabled={pending} onClick={() => toggle(a)}>
                          {a.active ? 'Turn off' : 'Turn on'}
                        </Button>
                      )}
                    </div>
                  )}
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
      {resetting && <PasswordModal account={resetting} onClose={() => setResetting(null)} />}
      {changingRole && <RoleModal account={changingRole} roles={roles} onClose={() => setChangingRole(null)} />}
    </>
  );
}
