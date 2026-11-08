import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { AcceptForm } from './accept-form';
import { roleLabel } from '@/lib/staff-roles';

export default async function AcceptInvitePage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('get_invitation_preview', { p_token: token }).maybeSingle();

  const { data: state } = data?.valid ? await supabaseServiceRole().rpc('invite_account_state', { p_token: token }).maybeSingle<{ school_code: string }>() : { data: null };

  if (!data || !data.valid) {
    return (
      <div className="flex min-h-screen items-center justify-center p-4">
        <Card className="w-full max-w-sm">
          <CardHeader>
            <CardTitle>Invitation not valid</CardTitle>
            <CardDescription>
              This invitation link has expired, was already used, or does not exist. Ask your school to send a new one.
            </CardDescription>
          </CardHeader>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-sm" data-testid="invite-preview">
        <CardHeader>
          <CardTitle>Join {data.tenant_name}</CardTitle>
          <CardDescription>
            You&apos;ve been invited as <span className="font-medium text-foreground">{roleLabel(data.app_role)}</span>. Set a
            password to finish creating your account.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <AcceptForm token={token} email={data.email} schoolCode={state?.school_code ?? null} />
        </CardContent>
      </Card>
    </div>
  );
}
