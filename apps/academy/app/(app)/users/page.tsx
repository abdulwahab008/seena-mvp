import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { STAFF_ROLE_OPTIONS } from '@/lib/staff-roles';
import { Alert } from '@/components/ui/alert';
import { PageHeader } from '@/components/ui/page-header';
import { NewAccountButton } from './new-account-form';
import { UserList } from './user-list';
import { BulkPasswordReset } from './bulk-reset';

export const dynamic = 'force-dynamic';

const MANAGERS = ['super_admin', 'owner', 'principal'];

// Mirrors app.fn_can_grant_role so the role picker only offers what the database will accept.
function grantableRoles(actorRole: string) {
  return STAFF_ROLE_OPTIONS.filter((o) => actorRole === 'super_admin' || o.value !== 'super_admin');
}

export default async function UsersPage() {
  const actor = await getCurrentActor();
  if (!actor || !MANAGERS.includes(actor.role)) notFound();

  const supabase = await supabaseServer();
  const [{ data: accounts, error }, { data: campuses }, { data: tenant }, { data: sections }] =
    await Promise.all([
      supabase.rpc('list_user_accounts'),
      supabase.from('campus').select('id, name').eq('status', 'active').order('code'),
      supabase.from('tenant').select('slug').eq('id', actor.tenantId).maybeSingle(),
      supabase
        .from('class_section')
        .select('id, name, class_level(name_en, ordinal)')
        .eq('is_active', true),
    ]);
  const sectionOptions = (sections ?? [])
    .map((s) => ({ s, level: Array.isArray(s.class_level) ? s.class_level[0] : s.class_level }))
    .sort(
      (a, b) =>
        (a.level?.ordinal ?? 0) - (b.level?.ordinal ?? 0) || a.s.name.localeCompare(b.s.name),
    )
    .map(({ s, level }) => ({ id: s.id, label: `${level?.name_en ?? ''} ${s.name}`.trim() }));
  const roles = grantableRoles(actor.role);

  return (
    <>
      <div className="print:hidden">
        <PageHeader
          title="User accounts"
          description={`Every login in your school. Staff with a username sign in as username@${tenant?.slug ?? 'your-school'}.`}
          actions={
            <NewAccountButton
              roles={roles}
              campuses={campuses ?? []}
              schoolSlug={tenant?.slug ?? ''}
            />
          }
        />
        {error ? (
          <Alert variant="destructive" title="Could not load accounts">
            Reload the page to try again.
          </Alert>
        ) : (
          <UserList accounts={accounts ?? []} roles={roles} currentUserId={actor.userId} />
        )}
      </div>
      <BulkPasswordReset sections={sectionOptions} />
    </>
  );
}
