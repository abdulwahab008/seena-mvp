import { supabaseServer } from '@/lib/supabase/server';
import { InviteForm } from './invite-form';
import { AddStaffModal } from './add-staff-modal';
import { InvitationRow } from './invitation-row';
import { roleLabel } from '@/lib/staff-roles';
import { pickActiveCampus } from '@/lib/campus-context';
import { getCurrentActor } from '@/lib/hr/current-role';

// Who register_staff_member() allows.
const STAFF_REGISTRAR_ROLES = ['super_admin', 'owner', 'principal', 'hr_manager'];

export const dynamic = 'force-dynamic';

export default async function StaffPage() {
  const supabase = await supabaseServer();
  const actor = await getCurrentActor();

  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const { data: invitations } = await supabase
    .from('tenant_invitation')
    .select('id, email, app_role, expires_at, accepted_at')
    .is('accepted_at', null)
    .order('created_at', { ascending: false });

  const { data: subjects } = await supabase.from('subject').select('id, name_en, code').order('name_en');
  const { data: departments } = await supabase.from('department').select('id, name_en, code, name_ur').order('code');

  const firstCampus = (await pickActiveCampus(campuses));

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Staff Management</h1>
          <p className="text-sm text-muted-foreground">
            Register staff for HR and payroll, or invite someone to sign in.
          </p>
        </div>
        {firstCampus && actor && STAFF_REGISTRAR_ROLES.includes(actor.role) && (
          <AddStaffModal
            campusId={firstCampus.id}
            campusName={firstCampus.name}
            subjects={subjects ?? []}
            departments={departments ?? []}
          />
        )}
      </div>
      {firstCampus && actor && ['super_admin', 'owner', 'principal'].includes(actor.role) && (
        <div className="space-y-2 rounded-lg border p-4 bg-muted/10">
          <h2 className="text-sm font-semibold text-foreground">Quick Email Invitation</h2>
          <p className="text-xs text-muted-foreground">
            Creates a sign-in only. To put someone on HR records and payroll, use Register Staff Member and give their email there.
          </p>
          <InviteForm campusId={firstCampus.id} />
        </div>
      )}
      <div className="space-y-2">
        <h2 className="text-sm font-medium text-muted-foreground">Pending invitations</h2>
        {!invitations || invitations.length === 0 ? (
          <p className="text-sm text-muted-foreground">No pending invitations.</p>
        ) : (
          invitations.map((i) => (
            <InvitationRow
              key={i.id}
              id={i.id}
              email={i.email}
              role={roleLabel(i.app_role)}
              expires={new Date(i.expires_at).toLocaleDateString('en-GB', { timeZone: 'Asia/Karachi', day: 'numeric', month: 'short', year: 'numeric' })}
            />
          ))
        )}
      </div>
    </div>
  );
}
