import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent } from '@/components/ui/card';
import { InviteForm } from './invite-form';

export default async function StaffPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const { data: invitations } = await supabase
    .from('tenant_invitation')
    .select('id, email, app_role, expires_at, accepted_at')
    .is('accepted_at', null)
    .order('created_at', { ascending: false });

  const firstCampus = campuses?.[0];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff</h1>
        <p className="text-sm text-muted-foreground">FR-A07 — invite staff by email; they set a password to join.</p>
      </div>
      {firstCampus && <InviteForm campusId={firstCampus.id} />}
      <div className="space-y-2">
        <h2 className="text-sm font-medium text-muted-foreground">Pending invitations</h2>
        {!invitations || invitations.length === 0 ? (
          <p className="text-sm text-muted-foreground">No pending invitations.</p>
        ) : (
          invitations.map((i) => (
            <Card key={i.id} data-testid={`invite-row-${i.email}`}>
              <CardContent className="flex items-center justify-between p-3 text-sm">
                <span>
                  {i.email} — {i.app_role.replace(/_/g, ' ')}
                </span>
                <span className="text-muted-foreground">expires {new Date(i.expires_at).toLocaleDateString()}</span>
              </CardContent>
            </Card>
          ))
        )}
      </div>
    </div>
  );
}
