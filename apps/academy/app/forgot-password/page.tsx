import Link from 'next/link';
import { AuthShell } from '@/components/auth-shell';
import { ForgotPasswordForm } from './forgot-password-form';

export const dynamic = 'force-dynamic';

export default function ForgotPasswordPage() {
  return (
    <AuthShell
      title="Reset your password"
      description="Enter the email address you sign in with and we'll send you a reset link."
      footer={
        <Link href="/login" className="font-medium text-foreground underline">
          Back to sign in
        </Link>
      }
    >
      <ForgotPasswordForm />
    </AuthShell>
  );
}
