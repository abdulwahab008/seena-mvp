import Link from 'next/link';
import { KeyRound, Smartphone, UserRound, Users } from 'lucide-react';
import { AuthShell } from '@/components/auth-shell';
import { Alert } from '@/components/ui/alert';
import { safeRedirectTo } from '@/lib/auth/redirect';
import { supabaseServer } from '@/lib/supabase/server';
import { LoginForm } from './login-form';

export const dynamic = 'force-dynamic';

const WHO = [
  { icon: UserRound, title: 'Staff', text: 'Your email, or username@school-code if the school gave you a username.' },
  { icon: KeyRound, title: 'Students', text: 'Your GR number and the password on your slip.' },
  { icon: Users, title: 'Parents', text: 'Sign in with your mobile number: we text you a code.' },
];

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ redirectTo?: string; signed_out?: string; reset?: string; school?: string }>;
}) {
  const params = await searchParams;

  // safeRedirectTo() rejects anything that is not a same-origin relative
  // path, so a phishing link like /login?redirectTo=https://evil.example
  // silently falls back to /dashboard instead of bouncing the user off-site
  // moments after they type their password.
  const redirectTo = safeRedirectTo(params.redirectTo);
  const schoolCode = params.school && /^[a-z0-9-]{3,50}$/i.test(params.school) ? params.school.toLowerCase() : null;
  const { data: schoolName } = schoolCode ? await (await supabaseServer()).rpc('school_login_name', { p_code: schoolCode }) : { data: null };

  return (
    <AuthShell
      title={schoolName ? `Sign in to ${schoolName}` : 'Sign in'}
      description={schoolName ? 'Welcome back.' : 'Welcome back to Seena Academy.'}
      aside={
        <div className="space-y-6">
          <h2 className="text-2xl font-semibold">How to sign in</h2>
          <ul className="space-y-5">
            {WHO.map((w) => (
              <li key={w.title} className="flex gap-3">
                <w.icon className="mt-0.5 h-5 w-5 shrink-0 opacity-80" aria-hidden />
                <span>
                  <span className="block font-medium">{w.title}</span>
                  <span className="text-sm opacity-80">{w.text}</span>
                </span>
              </li>
            ))}
          </ul>
          <p className="text-sm opacity-80">First time? Open the invitation link your school sent you by email, SMS or WhatsApp to set your password.</p>
        </div>
      }
      footer={
        <>
          <p>
            Got an invitation? Open the link in your message to get started.
          </p>
          <p>
            New school?{' '}
            <Link href="/register-school" className="font-medium text-foreground underline">
              Register your school
            </Link>
          </p>
        </>
      }
    >
      {params.reset ? (
        <Alert variant="success" title="Password updated" data-testid="reset-success">
          <p>Your password has been changed. Sign in with your new password.</p>
        </Alert>
      ) : null}
      {params.signed_out ? (
        <Alert variant="info" data-testid="signed-out-notice">
          <p>You have been signed out.</p>
        </Alert>
      ) : null}

      <LoginForm redirectTo={redirectTo} schoolCode={schoolName ? schoolCode : null} />

      <div className="relative py-1 text-center text-xs uppercase text-muted-foreground">
        <span className="relative z-10 bg-card px-2">or</span>
        <span className="absolute inset-x-0 top-1/2 border-t" aria-hidden />
      </div>
      <Link
        href="/login/otp"
        className="flex w-full items-center justify-center gap-2 rounded-md border px-4 py-2 text-sm font-medium transition-colors hover:bg-muted"
      >
        <Smartphone className="h-4 w-4" aria-hidden />
        Sign in with a code to my phone
      </Link>
      <div className="text-center text-sm">
        <Link href="/forgot-password" className="text-muted-foreground underline">
          Forgot password?
        </Link>
      </div>
    </AuthShell>
  );
}
