import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent } from '@/components/ui/card';
import { InviteForm } from './invite-form';
import { AddStaffModal } from './add-staff-modal';

export const dynamic = 'force-dynamic';

export default async function StaffPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const { data: invitations } = await supabase
    .from('tenant_invitation')
    .select('id, email, app_role, expires_at, accepted_at')
    .is('accepted_at', null)
    .order('created_at', { ascending: false });

  const { data: subjects } = await supabase.from('subject').select('id, name_en, code').order('name_en');
  const { data: departments } = await supabase.from('department').select('id, name_en, code, name_ur').order('code');

  const firstCampus = campuses?.[0];

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Staff Management</h1>
          <p className="text-sm text-muted-foreground">
            FR-A07 — Register official school staff records or send fast-track email invitations.
          </p>
        </div>
        {firstCampus && (
          <AddStaffModal
            campusId={firstCampus.id}
            campusName={firstCampus.name}
            subjects={subjects ?? []}
            departments={departments ?? []}
          />
        )}
      </div>
      {firstCampus && (
        <div className="space-y-2 rounded-lg border p-4 bg-muted/10">
          <h2 className="text-sm font-semibold text-foreground">Quick Email Invitation</h2>
          <p className="text-xs text-muted-foreground">Invite a staff member via email to create their own password and profile.</p>
          <InviteForm campusId={firstCampus.id} />
        </div>
      )}
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
