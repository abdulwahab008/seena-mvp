import { redirect } from 'next/navigation';
import { Building2 } from 'lucide-react';
import { cn } from '@/lib/utils';
import { supabaseServer } from '@/lib/supabase/server';
import { requireSession } from '@/lib/auth/require-session';
import { hasNoCampusAssigned } from '@/lib/campus-scope';
import { logFeatureResolveFailure, resolveFeatureSet } from '@/lib/features';
import { isImpersonationSessionEnded, parseImpersonationClaim } from '@/lib/impersonation';
import { EmptyState } from '@/components/ui/empty-state';
import { AppHeader } from './app-header';
import { ImpersonationBanner } from './impersonation-banner';
import { ImpersonationEnded } from './impersonation-ended';
import { Sidebar } from './sidebar';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await requireSession();
  const supabase = await supabaseServer();

  // FR-A16. Read off the verified token rather than off a route or a cookie:
  // this is the same claim the database is reading when it decides what the
  // request may see, so the banner cannot disagree with the enforcement.
  const { data: verified } = await supabase.auth.getClaims();
  const imp = parseImpersonationClaim(verified?.claims);

  const { data: appUser, error: appUserError } = await supabase
    .from('app_user')
    .select('app_role, tenant_id')
    .eq('user_id', user.id)
    .maybeSingle();

  // AC4: app.auth_tenant_id() re-checks the session and the consent on every
  // RLS-mediated read, so a withdrawal lands here — on the next request —
  // rather than at the next token refresh.
  if (imp && appUserError && isImpersonationSessionEnded(appUserError.message)) {
    return <ImpersonationEnded />;
  }

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

  // The banner is built before the campus gate below so it renders on that
  // screen too — an engineer who lands on a dead end must still be told, and
  // still be given the way out.
  let banner: React.ReactNode = null;
  if (imp) {
    const { data: target } = await supabase
      .from('app_user')
      .select('full_name')
      .eq('user_id', imp.sub)
      .maybeSingle();

    banner = (
      <ImpersonationBanner
        sessionId={imp.sid}
        targetName={target?.full_name ?? 'this user'}
        targetRole={String(verified?.claims.app_role ?? appUser.app_role)}
        engineerEmail={user.email ?? 'your support account'}
        endsAt={imp.exp}
      />
    );
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
      <div className={cn('flex min-h-screen items-center justify-center p-6', imp && 'pt-16')}>
        {banner}
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
    <div className={cn('flex min-h-screen bg-background', imp && 'pt-11')}>
      {banner}
      <Sidebar schoolName={schoolName} features={features} impersonating={!!imp} />
      <div className="flex min-w-0 flex-1 flex-col">
        <AppHeader
          email={user.email ?? 'Signed in'}
          role={appUser.app_role}
          schoolName={schoolName}
          features={features}
          impersonating={!!imp}
        />
        <main className="mx-auto w-full max-w-[90rem] flex-1 px-4 py-6 sm:px-6 lg:px-8">
          {children}
        </main>
      </div>
    </div>
  );
}
