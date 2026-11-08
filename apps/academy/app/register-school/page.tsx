import Link from 'next/link';
import { AuthShell } from '@/components/auth-shell';
import { RegistrationForm } from './registration-form';

export const metadata = { title: 'Register your school · Seena Academy' };

export default function RegisterSchoolPage() {
  return (
    <AuthShell
      wide
      title="Register your school"
      description="Tell us about your school. We set it up with you and send the owner a sign-in link. Staff, parents and students are then added by the school."
      footer={
        <>
          Already using Seena?{' '}
          <Link href="/login" className="font-medium text-foreground underline">
            Sign in
          </Link>
        </>
      }
    >
      <RegistrationForm />
    </AuthShell>
  );
}
