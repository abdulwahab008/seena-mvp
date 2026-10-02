import Link from 'next/link';
import { AuthShell } from '@/components/auth-shell';
import { Alert } from '@/components/ui/alert';
import { safeRedirectTo } from '@/lib/auth/redirect';
import { LoginForm } from './login-form';

export const dynamic = 'force-dynamic';

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ redirectTo?: string; signed_out?: string; reset?: string }>;
}) {
  const params = await searchParams;

  // safeRedirectTo() rejects anything that is not a same-origin relative
  // path, so a phishing link like /login?redirectTo=https://evil.example
  // silently falls back to /dashboard instead of bouncing the user off-site
  // moments after they type their password.
  const redirectTo = safeRedirectTo(params.redirectTo);

  return (
    <AuthShell
      title="Sign in"
      description="Welcome back."
      footer={
        <>
          Don&apos;t have an account?{' '}
          <Link href="/sign-up" className="font-medium text-foreground underline">
            Create one
          </Link>
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

      <LoginForm redirectTo={redirectTo} />

      <div className="flex items-center justify-between text-sm">
        <Link href="/forgot-password" className="text-muted-foreground underline">
          Forgot password?
        </Link>
        <Link href="/login/otp" className="text-muted-foreground underline">
          Use a mobile number
        </Link>
      </div>
    </AuthShell>
  );
}
