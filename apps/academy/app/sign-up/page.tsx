import Link from 'next/link';
import { redirect } from 'next/navigation';
import { AuthShell } from '@/components/auth-shell';
import { Alert } from '@/components/ui/alert';
import { supabaseServer } from '@/lib/supabase/server';
import { SignUpForm } from './sign-up-form';

export const dynamic = 'force-dynamic';

/**
 * DESIGN NOTE — why sign-up never creates a tenant, and never joins one.
 *
 * Seena Academy is multi-tenant and invitation-based: membership is an
 * app_user row, created either by provision_tenant() (service-role, behind
 * ADMIN_SETUP_TOKEN) or by accept_invitation(), which requires the secret
 * token from an invitation email.
 *
 * 1. Self-serve sign-up must not provision a tenant. provision_tenant() is
 *    granted to service_role alone and gated behind a bootstrap secret on
 *    purpose; letting an anonymous form create schools would hand anyone an
 *    unbounded tenant factory and contradict that model outright.
 *
 * 2. It must not auto-join a pending invitation either, even one matching the
 *    typed address. supabase/config.toml sets enable_confirmations = false,
 *    so at sign-up time the address is UNVERIFIED — nothing proves the person
 *    typing it owns it. Honouring an invitation on a typed address alone
 *    would let anyone who merely knows a colleague's email claim that
 *    invitation and inherit its app_role. The emailed token is precisely the
 *    proof of address ownership that sign-up lacks, which is why
 *    /accept-invite/[token] stays the only route to membership.
 *
 * What is left is an account with credentials and no tenant. That state is
 * handled explicitly rather than being allowed to strand the user: the form
 * lands on /no-school, and (app)/layout.tsx + portal/layout.tsx redirect any
 * membership-less session there instead of rendering an app shell whose every
 * RLS-scoped query returns nothing.
 */
export default async function SignUpPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (user) redirect('/dashboard');

  return (
    <AuthShell
      title="Create your account"
      description="Set up your sign-in details for Seena Academy."
      footer={
        <>
          Already have an account?{' '}
          <Link href="/login" className="font-medium text-foreground underline">
            Sign in
          </Link>
        </>
      }
    >
      <Alert variant="info" data-testid="sign-up-invite-notice">
        <p>
          Schools add their own staff and parents. Creating an account here does not join a school —
          you will still need the invitation link your school emails you.
        </p>
      </Alert>
      <SignUpForm />
    </AuthShell>
  );
}
