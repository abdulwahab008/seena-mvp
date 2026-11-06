import { redirect } from 'next/navigation';
import { AuthShell } from '@/components/auth-shell';
import { Alert } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { supabaseServer } from '@/lib/supabase/server';

export const dynamic = 'force-dynamic';

/**
 * Landing for a signed-in account with no app_user row — i.e. real
 * credentials, no school. Reachable two ways: straight after /sign-up, and
 * from (app)/layout.tsx or portal/layout.tsx redirecting a membership-less
 * session here.
 *
 * Without this page such a session renders the full app shell while every
 * RLS-scoped query underneath it returns nothing, which looks like a broken
 * product rather than an account that simply is not in a school yet.
 */
export default async function NoSchoolPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: appUser } = await supabase
    .from('app_user')
    .select('user_id')
    .eq('user_id', user.id)
    .maybeSingle();
  if (appUser) redirect('/dashboard');

  const { data: isPlatformAdmin } = await supabase.rpc('is_platform_admin');
  if (isPlatformAdmin) redirect('/platform');

  const { data: school } = await supabase.rpc('my_school_status').maybeSingle();
  if (school && school.status !== 'active') {
    return (
      <AuthShell title={`${school.tenant_name} is ${school.status === 'closed' ? 'closed' : 'suspended'}`} description={user.email ?? undefined}>
        <Alert variant="warning" title="You can't sign in to this school right now" data-testid="school-suspended">
          <p>
            {school.status === 'closed'
              ? 'This school no longer uses Seena Academy.'
              : 'Access to this school has been paused. Your data is safe. Please contact your school administrator.'}
          </p>
        </Alert>
        <form action="/api/auth/sign-out" method="post">
          <Button type="submit" variant="outline" className="w-full" data-testid="no-school-sign-out">
            Sign out
          </Button>
        </form>
      </AuthShell>
    );
  }

  return (
    <AuthShell title="You're not in a school yet" description={user.email ?? undefined}>
      <Alert variant="info" title="Your account is ready" data-testid="no-school">
        <p>
          Schools invite their own staff and parents. Ask your school administrator to send an
          invitation to this email address, then open the link in that email to join.
        </p>
      </Alert>
      <p className="text-sm text-muted-foreground">
        Already have an invitation email? Open the link inside it — it will connect this account to
        your school.
      </p>
      <form action="/api/auth/sign-out" method="post">
        <Button type="submit" variant="outline" className="w-full" data-testid="no-school-sign-out">
          Sign out
        </Button>
      </form>
    </AuthShell>
  );
}
