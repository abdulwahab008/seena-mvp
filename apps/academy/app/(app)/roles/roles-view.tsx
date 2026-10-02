'use client';

import * as React from 'react';
import { toast } from 'sonner';
import { Plus, Users } from 'lucide-react';
import { createRole, deleteRole, reassignHolders, updateRole, type RoleActionState } from './actions';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';

export type PermissionOption = { code: string; module: string; label: string };
export type CustomRole = { id: string; code: string; name: string; permissions: string[] };
export type SystemRole = { id: string; name: string };

type Editing = { role: CustomRole | null } | null;

export function RolesView({
  permissions,
  grantable,
  roles,
  holderCounts,
}: {
  permissions: PermissionOption[];
  grantable: string[];
  roles: CustomRole[];
  systemRoles: SystemRole[];
  holderCounts: Record<string, number>;
}) {
  const [editing, setEditing] = React.useState<Editing>(null);
  const [blocked, setBlocked] = React.useState<{ role: CustomRole; holders: number } | null>(null);
  const [pending, startTransition] = React.useTransition();

  const byModule = React.useMemo(() => {
    const groups = new Map<string, PermissionOption[]>();
    for (const p of permissions) {
      if (!grantable.includes(p.code)) continue;
      groups.set(p.module, [...(groups.get(p.module) ?? []), p]);
    }
    return [...groups.entries()];
  }, [permissions, grantable]);

  const labelOf = (code: string) => permissions.find((p) => p.code === code)?.label ?? code;

  const run = (
    action: (prev: RoleActionState, fd: FormData) => Promise<RoleActionState>,
    fd: FormData,
    onOk: () => void,
    onFail?: (s: RoleActionState) => void,
  ) =>
    startTransition(async () => {
      const result = await action({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        onFail?.(result);
      } else {
        onOk();
      }
    });

  const onSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const fd = new FormData(event.currentTarget);
    const role = editing?.role ?? null;
    run(role ? updateRole : createRole, fd, () => {
      toast.success(role ? 'Role updated.' : 'Role created.');
      setEditing(null);
    });
  };

  const onDelete = (role: CustomRole) => {
    const fd = new FormData();
    fd.set('roleId', role.id);
    run(
      deleteRole,
      fd,
      () => toast.success('Role deleted.'),
      (s) => {
        if (s.holderCount) setBlocked({ role, holders: s.holderCount });
      },
    );
  };

  const onReassign = (role: CustomRole) => {
    const fd = new FormData();
    fd.set('fromRoleId', role.id);
    fd.set('toRoleId', '');
    run(reassignHolders, fd, () => {
      toast.success('Holders moved back to their built-in role.');
      setBlocked(null);
    });
  };

  return (
    <div className="space-y-6" data-testid="roles-view">
      <div className="flex justify-end">
        <Button onClick={() => setEditing({ role: null })} data-testid="new-role">
          <Plus className="mr-2 h-4 w-4" /> New role
        </Button>
      </div>

      {roles.length === 0 ? (
        <EmptyState
          icon={Users}
          title="No custom roles yet"
          description="Create one when a post at your school does not match any of the built-in roles."
          data-testid="roles-empty"
        />
      ) : (
        <div className="grid gap-4 sm:grid-cols-2">
          {roles.map((role) => (
            <Card key={role.id} data-testid={`role-${role.code}`}>
              <CardContent className="space-y-3 p-5">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <p className="font-medium">{role.name}</p>
                    <p className="text-xs text-muted-foreground" data-testid={`role-holders-${role.code}`}>
                      {holderCounts[role.id] ?? 0} holder(s)
                    </p>
                  </div>
                  <div className="flex gap-2">
                    <Button variant="outline" size="sm" onClick={() => setEditing({ role })} disabled={pending}>
                      Edit
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => onDelete(role)}
                      disabled={pending}
                      data-testid={`delete-role-${role.code}`}
                    >
                      Delete
                    </Button>
                  </div>
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {role.permissions.length === 0 ? (
                    <span className="text-xs text-muted-foreground">No permissions</span>
                  ) : (
                    role.permissions.map((code) => (
                      <Badge key={code} variant="outline">
                        {labelOf(code)}
                      </Badge>
                    ))
                  )}
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      <Modal
        open={editing !== null}
        onClose={() => setEditing(null)}
        size="lg"
        title={editing?.role ? 'Edit role' : 'New role'}
        description="Only the permissions you hold yourself are listed. Granting anything else is refused by the server, not just hidden here."
      >
        <form onSubmit={onSubmit} className="space-y-5" data-testid="role-form">
          {editing?.role ? <input type="hidden" name="roleId" value={editing.role.id} /> : null}
          <div className="space-y-2">
            <Label htmlFor="role-name">Role name</Label>
            <Input
              id="role-name"
              name="name"
              defaultValue={editing?.role?.name ?? ''}
              placeholder="Coordinator"
              maxLength={60}
              required
              data-testid="role-name"
            />
          </div>

          <div className="space-y-4">
            {byModule.map(([module, items]) => (
              <fieldset key={module} className="space-y-2">
                <legend className="text-sm font-medium">{module}</legend>
                <div className="grid gap-2 sm:grid-cols-2">
                  {items.map((p) => (
                    <label key={p.code} className="flex items-center gap-2 text-sm">
                      <input
                        type="checkbox"
                        name="permissions"
                        value={p.code}
                        defaultChecked={editing?.role?.permissions.includes(p.code) ?? false}
                        data-testid={`perm-${p.code}`}
                        className="h-4 w-4 rounded border-input"
                      />
                      {p.label}
                    </label>
                  ))}
                </div>
              </fieldset>
            ))}
          </div>

          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={() => setEditing(null)}>
              Cancel
            </Button>
            <Button type="submit" disabled={pending} data-testid="save-role">
              {editing?.role ? 'Save changes' : 'Create role'}
            </Button>
          </div>
        </form>
      </Modal>

      <Modal
        open={blocked !== null}
        onClose={() => setBlocked(null)}
        title="This role is still in use"
        description={
          blocked
            ? `${blocked.holders} user(s) hold ${blocked.role.name}. Move them off it before deleting.`
            : undefined
        }
        footer={
          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={() => setBlocked(null)}>
              Cancel
            </Button>
            <Button
              onClick={() => blocked && onReassign(blocked.role)}
              disabled={pending}
              data-testid="reassign-holders"
            >
              Move all to their built-in role
            </Button>
          </div>
        }
      />
    </div>
  );
}
