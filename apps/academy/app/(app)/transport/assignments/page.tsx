import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { currentRole, loose, pickCampus, TRANSPORT_STAFF } from '@/lib/transport/rpc';
import { assignTrip } from './actions';

export const dynamic = 'force-dynamic';

type Assignment = { assignment_id: string; route_id: string; shift: string; effective_from: string; effective_to: string | null; vehicle_reg_no: string; seat_capacity: number; driver_name: string; conductor_name: string | null; attendant_name: string | null };

export default async function AssignmentsPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const canManage = TRANSPORT_STAFF.includes(role);
  const canOverride = ['owner', 'super_admin', 'principal'].includes(role);

  const [{ data: routes }, { data: vehicles }, { data: crew }, { data: current }] = await Promise.all([
    supabase.from('transport_route').select('id, code, name, shift').eq('campus_id', campus.id).eq('active', true).order('code'),
    supabase.from('transport_vehicle').select('id, reg_no, seat_capacity').eq('campus_id', campus.id).eq('active', true).order('reg_no'),
    supabase.from('v_transport_crew_public').select('id, full_name, crew_role').eq('campus_id', campus.id).eq('active', true).order('full_name'),
    supabase.from('v_transport_route_crew').select('assignment_id, route_id, shift, effective_from, effective_to, vehicle_reg_no, seat_capacity, driver_name, conductor_name, attendant_name').eq('campus_id', campus.id),
  ]);
  const routeRows = (routes ?? []) as { id: string; code: string; name: string; shift: string }[];
  const routeName = new Map(routeRows.map((r) => [r.id, `${r.code} · ${r.name}`]));
  const crewRows = (crew ?? []) as { id: string; full_name: string; crew_role: string }[];
  const opt = (rows: { id: string; full_name: string; crew_role: string }[], r: string) => rows.filter((c) => c.crew_role === r).map((c) => ({ value: c.id, label: c.full_name }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Vehicle and crew assignment</h1>
        <p className="text-sm text-muted-foreground">
          FR-P02 and FR-P03 — a vehicle with an expired required document, or a driver with an expired or too-low licence, cannot be assigned. A Principal can override a blocked vehicle with a recorded reason.
        </p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">In service today</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="assignment-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Route</th>
                <th>Vehicle</th>
                <th>Driver</th>
                <th>Conductor</th>
                <th>Attendant</th>
                <th>Dates</th>
              </tr>
            </thead>
            <tbody>
              {((current ?? []) as Assignment[]).map((a) => (
                <tr key={a.assignment_id} className="border-t" data-testid="assignment-row">
                  <td className="py-1">{routeName.get(a.route_id) ?? a.route_id}</td>
                  <td>
                    {a.vehicle_reg_no} ({a.seat_capacity})
                  </td>
                  <td>{a.driver_name}</td>
                  <td>{a.conductor_name ?? '-'}</td>
                  <td>{a.attendant_name ?? '-'}</td>
                  <td>
                    {a.effective_from} to {a.effective_to ?? 'open'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>
      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Assign</CardTitle>
          </CardHeader>
          <CardContent>
            <SpecForm
              testId="assign-form"
              submitLabel="Assign"
              action={assignTrip}
              columns={3}
              fields={[
                { name: 'routeId', label: 'Route', type: 'select', required: true, options: routeRows.map((r) => ({ value: r.id, label: `${r.code} · ${r.name} (${r.shift})` })) },
                { name: 'vehicleId', label: 'Vehicle', type: 'select', required: true, options: ((vehicles ?? []) as { id: string; reg_no: string; seat_capacity: number }[]).map((v) => ({ value: v.id, label: `${v.reg_no} (${v.seat_capacity} seats)` })) },
                { name: 'driverId', label: 'Driver', type: 'select', required: true, options: opt(crewRows, 'driver') },
                { name: 'conductorId', label: 'Conductor', type: 'select', options: opt(crewRows, 'conductor') },
                { name: 'attendantId', label: 'Attendant', type: 'select', options: opt(crewRows, 'attendant') },
                { name: 'from', label: 'From', type: 'date', required: true },
                { name: 'to', label: 'Last day (blank = open)', type: 'date' },
                ...(canOverride ? [{ name: 'overrideReason', label: 'Principal override reason (only if the vehicle is blocked)', type: 'textarea' as const }] : []),
              ]}
            />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
