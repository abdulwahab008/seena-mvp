import Link from 'next/link';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { LoginForm } from './login-form';

export default function LoginPage() {
  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Seena Academy</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <LoginForm />
          <Link href="/login/otp" className="block text-center text-sm text-muted-foreground underline">
            Sign in with a mobile number instead
          </Link>
        </CardContent>
      </Card>
    </div>
  );
}
