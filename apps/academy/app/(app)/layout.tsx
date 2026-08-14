import { redirect } from 'next/navigation';
import { Building2 } from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { requireSession } from '@/lib/auth/require-session';
import { hasNoCampusAssigned } from '@/lib/campus-scope';
import { logFeatureResolveFailure, resolveFeatureSet } from '@/lib/features';
import { EmptyState } from '@/components/ui/empty-state';
import { AppHeader } from './app-header';
import { Sidebar } from './sidebar';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await requireSession();
  const supabase = await supabaseServer();

  const { data: appUser } = await supabase
    .from('app_user')
    .select('app_role, tenant_id')
    .eq('user_id', user.id)
    .maybeSingle();

  // A session with no app_user row would otherwise render this whole shell
  // around an app where every RLS-scoped query legitimately returns nothing.
  // Two very different people land here, so they are told apart before being
  // sent anywhere:
  //
  //  - an activated guardian, who has no app_user row by design (they are
  //    linked through guardian.auth_user_id, and custom_access_token_hook
  //    gives them app_role 'parent'). They have a home — it is the portal.
  //  - anyone else: credentials but no school, e.g. straight from /sign-up.
  if (!appUser) {
    const { data: guardian } = await supabase
      .from('guardian')
      .select('id')
      .eq('auth_user_id', user.id)
      .maybeSingle();
    redirect(guardian ? '/portal/homework' : '/no-school');
  }

  // FR-A12 AC4: a campus-scoped role (i.e. not owner/super_admin, whose
  // access is role-based, not user_campus-based) with zero active
  // user_campus rows has nothing to see anywhere — every campus-scoped RLS
  // policy already returns zero rows for them (campus_id = any('{}') is
  // never true), so this is purely a friendlier "why is everything empty"
  // screen, not an additional access-control layer.
  const { data: activeCampuses } = await supabase
    .from('user_campus')
    .select('campus_id')
    .eq('user_id', user.id)
    .eq('is_active', true);

  if (hasNoCampusAssigned(appUser.app_role, activeCampuses?.length ?? 0)) {
    return (
      <div className="flex min-h-screen items-center justify-center p-6">
        <EmptyState
          icon={Building2}
          className="max-w-md bg-card"
          title="No campus assigned"
          description="Your account isn't assigned to any campus yet. Ask your school's Owner or Principal to grant you access to one."
          data-testid="no-campus-assigned"
          titleTestId="no-campus-assigned-heading"
          descriptionTestId="no-campus-assigned-message"
        />
      </div>
    );
  }

  const { data: tenant } = await supabase.from('tenant').select('name').limit(1).single();
  const schoolName = tenant?.name ?? 'Your school';

  // FR-A17: the resolved flag set travels with the session bootstrap, and a
  // failed resolve falls back to the last-known-good set rather than blacking
  // out every optional module. Hiding a nav item is presentation only — each
  // gated module is enforced by its own RLS policy and write trigger.
  const { data: resolved, error: featureError } = await supabase.rpc('resolved_features');
  const { features, stale } = resolveFeatureSet(appUser.tenant_id, resolved, featureError);
  if (stale) logFeatureResolveFailure(appUser.tenant_id, featureError);

  return (
    <div className="flex min-h-screen bg-background">
      <Sidebar schoolName={schoolName} features={features} />
      <div className="flex min-w-0 flex-1 flex-col">
        <AppHeader
          email={user.email ?? 'Signed in'}
          role={appUser.app_role}
          schoolName={schoolName}
          features={features}
        />
        <main className="mx-auto w-full max-w-[90rem] flex-1 px-4 py-6 sm:px-6 lg:px-8">
          {children}
        </main>
      </div>
    </div>
  );
}
