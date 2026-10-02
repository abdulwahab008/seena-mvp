import Link from 'next/link';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { OtpForm } from './otp-form';

export default function OtpLoginPage() {
  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Sign in with your mobile number</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <OtpForm />
          <Link href="/login" className="block text-center text-sm text-muted-foreground underline">
            Sign in with a password instead
          </Link>
        </CardContent>
      </Card>
    </div>
  );
}
