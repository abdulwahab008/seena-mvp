import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { supabaseServer } from '@/lib/supabase/server';
import { ActivateForm } from './activate-form';

export default async function GuardianActivatePage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('get_guardian_invite_preview', { p_token: token }).maybeSingle();

  if (!data || !data.valid || !data.phone_e164) {
    return (
      <div className="flex min-h-screen items-center justify-center p-4">
        <Card className="w-full max-w-sm">
          <CardHeader>
            <CardTitle>Invite not valid</CardTitle>
            <CardDescription>This activation link has expired, was already used, or does not exist. Ask the school to send a new one.</CardDescription>
          </CardHeader>
        </Card>
      </div>
    );
  }

  if (data.locked) {
    return (
      <div className="flex min-h-screen items-center justify-center p-4">
        <Card className="w-full max-w-sm">
          <CardHeader>
            <CardTitle>Too many attempts</CardTitle>
            <CardDescription>This invite is temporarily locked after too many wrong codes. Try again in 30 minutes.</CardDescription>
          </CardHeader>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-sm" data-testid="guardian-activate-preview">
        <CardHeader>
          <CardTitle>Join {data.tenant_name}</CardTitle>
          <CardDescription>
            Activate your parent portal account, {data.guardian_name}.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ActivateForm token={token} phoneHint={data.is_claim ? (data.phone_masked ?? '') : data.phone_e164} />
        </CardContent>
      </Card>
    </div>
  );
}
