import { redirect } from 'next/navigation';
import { AuthShell } from '@/components/auth-shell';
import { requireSession } from '@/lib/auth/require-session';
import { ChangePasswordForm } from './change-password-form';

export const dynamic = 'force-dynamic';

export default async function ChangePasswordPage() {
  const user = await requireSession();
  if (user.app_metadata?.must_change_password !== true) redirect('/dashboard');

  return (
    <AuthShell title="Choose your own password" description="Your school gave you a temporary password. Set a new one to continue.">
      <ChangePasswordForm />
    </AuthShell>
  );
}
