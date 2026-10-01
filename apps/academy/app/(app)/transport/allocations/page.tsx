import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ActionButton, SpecForm } from '@/components/spec-form';
import { currentRole, loose, pickCampus, pkr, todayPk } from '@/lib/transport/rpc';
import { allocateStudent, endAllocation, joinWaitlist, moveStudent, postCharges, setProratePolicy } from './actions';

export const dynamic = 'force-dynamic';

type Alloc = {
  id: string; starts_on: string; ends_on: string | null; route_id: string; fare_slab_id: string;
  student: { name_en: string; gr_number: string } | { name_en: string; gr_number: string }[] | null;
  pickup: { name: string } | { name: string }[] | null;
};
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

const ALLOCATORS = ['owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager', 'accountant', 'admissions_officer'];
const POLICY_EDITORS = ['owner', 'super_admin', 'principal', 'accountant'];

export default async function AllocationsPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const today = todayPk();

  const [{ data: routes }, { data: stops }, { data: allocs }, { data: wait }, { data: assigns }, { data: policy }] = await Promise.all([
    supabase.from('transport_route').select('id, code, name').eq('campus_id', campus.id).order('code'),
    supabase.from('v_transport_route_sheet').select('stop_id, route_code, seq, stop_name, slab_code, monthly_amount_paisa').eq('campus_id', campus.id).order('route_code').order('seq'),
    supabase
      .from('transport_allocation')
      .select('id, starts_on, ends_on, route_id, fare_slab_id, student:student_id(name_en, gr_number), pickup:pickup_stop_id(name)')
      .eq('campus_id', campus.id)
      .or(`ends_on.is.null,ends_on.gte.${today}`)
      .order('starts_on', { ascending: false }),
    supabase.from('transport_waitlist').select('id, route_id, queued_at, student:student_id(name_en, gr_number)').eq('campus_id', campus.id).order('queued_at'),
    supabase.from('v_transport_route_crew').select('route_id, seat_capacity').eq('campus_id', campus.id),
    supabase.from('tenant_setting').select('value').eq('key', 'transport.prorate').maybeSingle(),
  ]);
  const mode = ((policy as { value: unknown } | null)?.value as string | undefined) ?? 'full_month';
  const routeRows = (routes ?? []) as { id: string; code: string; name: string }[];
  const seats = new Map(((assigns ?? []) as { route_id: string; seat_capacity: number }[]).map((a) => [a.route_id, a.seat_capacity]));
  const taken = new Map<string, number>();
  const allocRows = (allocs ?? []) as Alloc[];
  for (const a of allocRows) if (a.starts_on <= today) taken.set(a.route_id, (taken.get(a.route_id) ?? 0) + 1);
  const stopRows = (stops ?? []) as { stop_id: string; route_code: string; seq: number; stop_name: string; slab_code: string | null; monthly_amount_paisa: number | null }[];
  const stopOptions = stopRows.map((s) => ({ value: s.stop_id, label: `${s.route_code} · ${s.seq}. ${s.stop_name}${s.slab_code ? ` (${s.slab_code}, ${pkr(s.monthly_amount_paisa)})` : ''}` }));
  const canAllocate = ALLOCATORS.includes(role);
  const allocFields = (extra: 'allocate' | 'move') => [
    { name: 'grNumber', label: 'Student GR number', required: true },
    { name: 'pickupStopId', label: 'Pickup stop', type: 'select' as const, required: true, options: stopOptions },
    { name: 'dropStopId', label: 'Drop stop (blank = same)', type: 'select' as const, options: stopOptions },
    { name: 'from', label: extra === 'move' ? 'Changes from' : 'Starts on', type: 'date' as const, required: true, defaultValue: today },
  ];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Transport allocation</h1>
        <p className="text-sm text-muted-foreground">
          FR-P04 — the transport fee follows from the stop a student is allocated to. Seats are counted against the vehicle assigned to the route on the start date.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Seats by route</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-2 text-sm" data-testid="seat-summary">
          {routeRows.map((r) => (
            <Badge key={r.id} variant={seats.has(r.id) && (taken.get(r.id) ?? 0) >= (seats.get(r.id) ?? 0) ? 'destructive' : 'outline'}>
              {r.code}: {taken.get(r.id) ?? 0}/{seats.get(r.id) ?? 'no vehicle'}
            </Badge>
          ))}
        </CardContent>
      </Card>

      {canAllocate && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Allocate a student</CardTitle>
          </CardHeader>
          <CardContent>
            <SpecForm testId="allocate-form" submitLabel="Allocate" action={allocateStudent} columns={4} fields={allocFields('allocate')} />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Current allocations</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="allocation-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Student</th>
                <th>Route</th>
                <th>Pickup stop</th>
                <th>From</th>
                <th>Until</th>
                {canAllocate && <th />}
              </tr>
            </thead>
            <tbody>
              {allocRows.map((a) => (
                <tr key={a.id} className="border-t" data-testid="allocation-row">
                  <td className="py-1">
                    {one(a.student)?.name_en} <span className="text-muted-foreground">({one(a.student)?.gr_number})</span>
                  </td>
                  <td>{routeRows.find((r) => r.id === a.route_id)?.code}</td>
                  <td>{one(a.pickup)?.name}</td>
                  <td>{a.starts_on}</td>
                  <td>{a.ends_on ?? 'ongoing'}</td>
                  {canAllocate && <td>{!a.ends_on && <ActionButton label="End today" variant="ghost" confirm="End this student's bus service today?" action={() => endAllocation(a.id)} />}</td>}
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>

      {canAllocate && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Change a student&apos;s stop</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <p className="text-muted-foreground">The old allocation closes the day before and the month&apos;s fee is split between the two stops; it never exceeds the dearest slab.</p>
            <SpecForm testId="move-form" submitLabel="Change stop" action={moveStudent} columns={4} fields={allocFields('move')} />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Waiting list</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          <ul data-testid="waitlist">
            {((wait ?? []) as { id: string; route_id: string; queued_at: string; student: { name_en: string; gr_number: string } | { name_en: string; gr_number: string }[] | null }[]).map((w) => (
              <li key={w.id}>
                {routeRows.find((r) => r.id === w.route_id)?.code} · {one(w.student)?.name_en} ({one(w.student)?.gr_number}) queued {w.queued_at.slice(0, 10)}
              </li>
            ))}
          </ul>
          {canAllocate && (
            <SpecForm
              testId="waitlist-form"
              submitLabel="Add to waiting list"
              action={joinWaitlist}
              columns={3}
              fields={[
                { name: 'grNumber', label: 'Student GR number', required: true },
                { name: 'routeId', label: 'Route', type: 'select', required: true, options: routeRows.map((r) => ({ value: r.id, label: `${r.code} · ${r.name}` })) },
              ]}
            />
          )}
        </CardContent>
      </Card>

      {POLICY_EDITORS.includes(role) && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Fee policy and monthly posting</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <p className="text-muted-foreground">
              Part-month policy is currently <strong>{mode === 'prorata' ? 'pro-rata by days' : 'full month once the bus is used'}</strong>. Charges post automatically on the 1st, ahead of challan generation.
            </p>
            <SpecForm
              testId="policy-form"
              submitLabel="Save policy"
              action={setProratePolicy}
              resetOnSuccess={false}
              columns={2}
              fields={[{ name: 'mode', label: 'First/last month', type: 'select', required: true, defaultValue: mode, options: [{ value: 'full_month', label: 'Full month' }, { value: 'prorata', label: 'Pro-rata by days' }] }]}
            />
            <SpecForm testId="post-form" submitLabel="Post charges now" action={postCharges} columns={2} fields={[{ name: 'month', label: 'Month (any day in it)', type: 'date', required: true, defaultValue: today }]} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
