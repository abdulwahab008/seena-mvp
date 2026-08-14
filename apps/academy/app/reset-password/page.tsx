import Link from 'next/link';
import { AuthShell } from '@/components/auth-shell';
import { Alert } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { supabaseServer } from '@/lib/supabase/server';
import { ResetPasswordForm } from './reset-password-form';

export const dynamic = 'force-dynamic';

/**
 * Each failure mode gets its own wording. GoTrue cannot supply that — expired,
 * spent and forged tokens all come back as the same 403 otp_expired — so the
 * distinction comes from our own ledger via classify_password_reset_token(),
 * which is read-only and does NOT consume the token. Redemption happens on
 * submit, in the server action, where verifyOtp() re-decides for real.
 */
const FAILURES = {
  used: {
    title: 'This link has already been used',
    body: 'Your password was already changed with this link. Sign in with your new password, or request another link if you still need one.',
  },
  expired: {
    title: 'This link has expired',
    body: 'Password reset links are valid for one hour. Request a new one and it will arrive within a few minutes.',
  },
  unknown: {
    title: 'This link is not valid',
    body: "We don't recognise this reset link. It may have been copied incompletely from the email — try requesting a fresh one.",
  },
  missing: {
    title: 'No reset link found',
    body: 'Open the link from your password reset email, or request a new one below.',
  },
} as const;

type Failure = keyof typeof FAILURES;

export default async function ResetPasswordPage({
  searchParams,
}: {
  searchParams: Promise<{ token_hash?: string }>;
}) {
  const { token_hash: tokenHash } = await searchParams;

  let failure: Failure | null = null;

  if (!tokenHash) {
    failure = 'missing';
  } else {
    const supabase = await supabaseServer();
    const { data, error } = await supabase.rpc('classify_password_reset_token', {
      p_token_hash: tokenHash,
    });
    if (error) {
      console.error('[reset-password] classify failed:', error.message);
      failure = 'unknown';
    } else if (data !== 'valid') {
      failure = (data as Failure | null) ?? 'unknown';
      if (!(failure in FAILURES)) failure = 'unknown';
    }
  }

  if (failure) {
    const { title, body } = FAILURES[failure];
    return (
      <AuthShell
        title="Reset your password"
        footer={
          <Link href="/login" className="font-medium text-foreground underline">
            Back to sign in
          </Link>
        }
      >
        <Alert variant="warning" title={title} data-testid={`reset-token-${failure}`}>
          <p>{body}</p>
        </Alert>
        <Button asChild className="w-full">
          <Link href="/forgot-password">Request a new link</Link>
        </Button>
      </AuthShell>
    );
  }

  return (
    <AuthShell
      title="Choose a new password"
      description="Pick something you haven't used on this account before."
      footer={
        <Link href="/login" className="font-medium text-foreground underline">
          Back to sign in
        </Link>
      }
    >
      <ResetPasswordForm tokenHash={tokenHash!} />
    </AuthShell>
  );
}
