import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { ClaimForm } from './claim-form';

export default function GuardianClaimPage() {
  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-sm" data-testid="guardian-claim-card">
        <CardHeader>
          <CardTitle>Activate your parent account</CardTitle>
          <CardDescription>
            Use your child&apos;s GR number and the last 6 digits of your CNIC. We&apos;ll send a code to the phone number the school has on file.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ClaimForm />
        </CardContent>
      </Card>
    </div>
  );
}
