import { ShieldCheck } from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { EmptyState } from '@/components/ui/empty-state';
import { PageHeader } from '@/components/ui/page-header';
import { RolesView, type CustomRole, type PermissionOption } from './roles-view';

export default async function RolesPage() {
  const supabase = await supabaseServer();

  // The caller's own effective permissions are the picker's universe, and
  // create_custom_role re-checks the same set server-side — the picker
  // narrowing the list is only there so nobody is offered a checkbox that is
  // going to be refused.
  const { data: grantable } = await supabase.rpc('my_effective_permissions');
  const grantableCodes = (grantable ?? []) as string[];

  if (!grantableCodes.includes('role.manage')) {
    return (
      <div className="space-y-6">
        <PageHeader title="Roles" description="Custom roles for posts that are not one of the built-in roles." />
        <EmptyState
          icon={ShieldCheck}
          title="You cannot manage roles"
          description="Only someone with the Create and edit roles permission can add or change a custom role. Ask your Owner or Principal."
          data-testid="roles-forbidden"
        />
      </div>
    );
  }

  const [{ data: permissions }, { data: roles }] = await Promise.all([
    supabase.from('permission').select('code, module, label').order('module').order('code'),
    supabase
      .from('role')
      .select('id, code, name, is_system, role_permission(permission_code)')
      .not('tenant_id', 'is', null)
      .is('deleted_at', null)
      .order('is_system', { ascending: false })
      .order('name'),
  ]);

  const allRoles = (roles ?? []).map((r) => ({
    id: r.id as string,
    code: r.code as string,
    name: r.name as string,
    isSystem: r.is_system as boolean,
    permissions: ((r.role_permission ?? []) as { permission_code: string }[]).map((p) => p.permission_code),
  }));

  const customRoles: CustomRole[] = allRoles.filter((r) => !r.isSystem);

  const counts = await Promise.all(
    customRoles.map(async (r) => {
      const { data } = await supabase.rpc('custom_role_holder_count', { p_role_id: r.id });
      return [r.id, (data as number | null) ?? 0] as const;
    }),
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Roles"
        description="A custom role is a named bundle of permissions layered on top of a person's built-in role. It can narrow what they may do — it can never grant more than their built-in role, or more than you hold yourself."
      />
      <RolesView
        permissions={(permissions ?? []) as PermissionOption[]}
        grantable={grantableCodes}
        roles={customRoles}
        systemRoles={allRoles.filter((r) => r.isSystem).map((r) => ({ id: r.id, name: r.name }))}
        holderCounts={Object.fromEntries(counts)}
      />
    </div>
  );
}
