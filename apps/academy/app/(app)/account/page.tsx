import { redirect } from 'next/navigation';
import { Mail, Shield } from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { Button } from '@/components/ui/button';

export const dynamic = 'force-dynamic';

export default async function AccountPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: appUser } = await supabase
    .from('app_user')
    .select('app_role, full_name')
    .eq('user_id', user.id)
    .single();

  const { data: campuses } = await supabase
    .from('user_campus')
    .select('campus:campus_id(name, code)')
    .eq('user_id', user.id)
    .eq('is_active', true);

  return (
    <>
      <PageHeader title="Your profile" description="How this account is identified and what it can reach." />

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Account</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <div className="flex items-start gap-3">
              <Mail className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
              <div className="min-w-0">
                <p className="text-muted-foreground">Email</p>
                <p className="truncate font-medium">{user.email}</p>
              </div>
            </div>
            {appUser?.full_name ? (
              <div className="flex items-start gap-3">
                <span className="mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center text-xs text-muted-foreground">
                  @
                </span>
                <div className="min-w-0">
                  <p className="text-muted-foreground">Name</p>
                  <p className="truncate font-medium">{appUser.full_name}</p>
                </div>
              </div>
            ) : null}
            <div className="flex items-start gap-3">
              <Shield className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
              <div className="min-w-0">
                <p className="text-muted-foreground">Role</p>
                <p className="font-medium capitalize">{(appUser?.app_role ?? 'member').replace(/_/g, ' ')}</p>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Campus access</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            {(campuses?.length ?? 0) === 0 ? (
              <p className="text-muted-foreground">
                No campus is assigned to this account. Owners and Super Admins reach every campus by role.
              </p>
            ) : (
              <div className="flex flex-wrap gap-2">
                {campuses!.map((c, i) => {
                  const campus = c.campus as unknown as { name: string; code: string } | null;
                  return (
                    <Badge key={i} variant="primary">
                      {campus?.name ?? campus?.code ?? 'Campus'}
                    </Badge>
                  );
                })}
              </div>
            )}
          </CardContent>
        </Card>

        <Card className="lg:col-span-2">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Password</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center justify-between gap-3 text-sm">
            <p className="text-muted-foreground">
              Change your password by requesting a reset link — it is sent to the address above.
            </p>
            <Button asChild variant="outline" size="sm">
              <a href="/forgot-password">Send reset link</a>
            </Button>
          </CardContent>
        </Card>
      </div>
    </>
  );
}
