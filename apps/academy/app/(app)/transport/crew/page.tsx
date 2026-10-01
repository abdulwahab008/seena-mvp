import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { currentRole, loose, pickCampus, todayPk } from '@/lib/transport/rpc';
import { saveCrew } from './actions';

export const dynamic = 'force-dynamic';

type Crew = {
  id: string; full_name: string; crew_role: string; phone: string | null; cnic: string | null;
  licence_class: string | null; licence_expires_on: string | null; police_verified_on: string | null; active: boolean;
};

const EDITORS = ['owner', 'super_admin', 'principal', 'transport_manager', 'hr_manager'];

export default async function CrewPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const today = todayPk();
  const { data } = await supabase
    .from('v_transport_crew_public')
    .select('id, full_name, crew_role, phone, cnic, licence_class, licence_expires_on, police_verified_on, active')
    .eq('campus_id', campus.id)
    .order('crew_role')
    .order('full_name');
  const crew = (data ?? []) as Crew[];
  const policeStale = (c: Crew) => !c.police_verified_on || Date.parse(c.police_verified_on) < Date.parse(today) - 365 * 86400000;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Drivers and crew</h1>
        <p className="text-sm text-muted-foreground">
          FR-P03 — licences, classes and police verification. An expired licence or a class too low for the bus blocks the assignment; a lapsed police verification is a warning. CNIC is masked unless your role may see it.
        </p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Crew</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="crew-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Name</th>
                <th>Role</th>
                <th>CNIC</th>
                <th>Licence</th>
                <th>Police verification</th>
              </tr>
            </thead>
            <tbody>
              {crew.map((c) => (
                <tr key={c.id} className="border-t" data-testid="crew-row">
                  <td className="py-1">{c.full_name}</td>
                  <td>{c.crew_role}</td>
                  <td data-testid="crew-cnic">{c.cnic ?? '-'}</td>
                  <td>
                    {c.licence_class ? (
                      <Badge variant={c.licence_expires_on && c.licence_expires_on < today ? 'destructive' : 'success'}>
                        {c.licence_class} until {c.licence_expires_on}
                      </Badge>
                    ) : (
                      '-'
                    )}
                  </td>
                  <td>{c.crew_role === 'driver' ? policeStale(c) ? <Badge variant="warning">{c.police_verified_on ? `stale (${c.police_verified_on})` : 'not recorded'}</Badge> : c.police_verified_on : '-'}</td>
                </tr>
              ))}
              {crew.length === 0 && (
                <tr>
                  <td colSpan={5} className="py-2 text-muted-foreground">
                    No crew yet.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </CardContent>
      </Card>
      {EDITORS.includes(role) && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add crew</CardTitle>
          </CardHeader>
          <CardContent>
            <SpecForm
              testId="crew-form"
              submitLabel="Add crew member"
              action={saveCrew}
              columns={4}
              fields={[
                { name: 'campusId', label: 'Campus', type: 'hidden', defaultValue: campus.id },
                { name: 'fullName', label: 'Full name', required: true },
                { name: 'cnic', label: 'CNIC', required: true, placeholder: '35202-1234567-1' },
                { name: 'crewRole', label: 'Role', type: 'select', required: true, options: [{ value: 'driver', label: 'Driver' }, { value: 'conductor', label: 'Conductor' }, { value: 'attendant', label: 'Attendant' }] },
                { name: 'phone', label: 'Phone' },
                { name: 'licenceNo', label: 'Licence no. (drivers)' },
                { name: 'licenceClass', label: 'Licence class', type: 'select', options: [{ value: 'LTV', label: 'LTV' }, { value: 'HTV', label: 'HTV' }, { value: 'PSV', label: 'PSV' }] },
                { name: 'licenceExpiresOn', label: 'Licence expires', type: 'date' },
                { name: 'policeVerifiedOn', label: 'Police verified on', type: 'date' },
                { name: 'bloodGroup', label: 'Blood group', type: 'select', options: ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'].map((b) => ({ value: b, label: b })) },
              ]}
            />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
