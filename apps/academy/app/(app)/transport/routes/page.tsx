import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { currentRole, loose, pickCampus, pkr, TRANSPORT_STAFF } from '@/lib/transport/rpc';
import { createRoute, saveFareSlab } from './actions';

export const dynamic = 'force-dynamic';

type Route = { id: string; code: string; name: string; shift: string; active: boolean };
type Slab = { id: string; code: string; name: string; monthly_amount_paisa: number; effective_from: string };

export default async function TransportRoutesPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const canManage = TRANSPORT_STAFF.includes(role);

  const [{ data: routes }, { data: slabs }, { data: stopCounts }] = await Promise.all([
    supabase.from('transport_route').select('id, code, name, shift, active').eq('campus_id', campus.id).order('code'),
    supabase.from('transport_fare_slab').select('id, code, name, monthly_amount_paisa, effective_from').eq('campus_id', campus.id).order('code').order('effective_from', { ascending: false }),
    supabase.from('transport_stop').select('route_id').eq('campus_id', campus.id),
  ]);
  const counts = new Map<string, number>();
  for (const s of (stopCounts ?? []) as { route_id: string }[]) counts.set(s.route_id, (counts.get(s.route_id) ?? 0) + 1);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Transport routes</h1>
        <p className="text-sm text-muted-foreground">
          FR-P01 — each route is an ordered list of stops with pickup and drop times; the fare comes from the stop&apos;s fare slab, never from a per-student figure.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Routes</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="route-list">
          {((routes ?? []) as Route[]).length === 0 && <p className="text-muted-foreground">No routes yet.</p>}
          {((routes ?? []) as Route[]).map((r) => (
            <div key={r.id} className="flex items-center justify-between gap-3 border-b pb-2" data-testid="route-row">
              <Link href={`/transport/routes/${r.id}`} className="font-medium hover:underline">
                {r.code} · {r.name}
              </Link>
              <span className="flex items-center gap-2">
                <Badge variant="outline">{r.shift}</Badge>
                <span className="text-xs text-muted-foreground">{counts.get(r.id) ?? 0} stops</span>
                {!r.active && <Badge variant="warning">inactive</Badge>}
              </span>
            </div>
          ))}
        </CardContent>
      </Card>

      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add a route</CardTitle>
          </CardHeader>
          <CardContent>
            <SpecForm
              testId="route-form"
              submitLabel="Add route"
              action={createRoute}
              fields={[
                { name: 'campusId', label: 'Campus', type: 'hidden', defaultValue: campus.id },
                { name: 'code', label: 'Route code', required: true, placeholder: 'R-04' },
                { name: 'name', label: 'Route name', required: true, placeholder: 'Johar Town Morning' },
                { name: 'shift', label: 'Shift', type: 'select', required: true, options: [{ value: 'morning', label: 'Morning' }, { value: 'afternoon', label: 'Afternoon' }] },
                { name: 'active', label: 'Active', type: 'checkbox', defaultValue: 'true' },
              ]}
            />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Fare slabs</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm">
          <table className="w-full" data-testid="slab-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Slab</th>
                <th>Monthly fare</th>
                <th>Effective from</th>
              </tr>
            </thead>
            <tbody>
              {((slabs ?? []) as Slab[]).map((s) => (
                <tr key={s.id} className="border-t" data-testid="slab-row">
                  <td className="py-1">
                    {s.code} · {s.name}
                  </td>
                  <td>{pkr(s.monthly_amount_paisa)}</td>
                  <td>{s.effective_from}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {canManage && (
            <>
              <p className="text-muted-foreground">
                To revise a fare, save the same slab code with the new amount and the date it takes effect. Every student on the slab is re-priced from that month; nothing is edited per student.
              </p>
              <SpecForm
                testId="slab-form"
                submitLabel="Save slab"
                action={saveFareSlab}
                fields={[
                  { name: 'campusId', label: 'Campus', type: 'hidden', defaultValue: campus.id },
                  { name: 'code', label: 'Slab code', required: true, placeholder: 'ZONE-B' },
                  { name: 'name', label: 'Slab name', required: true, placeholder: 'Zone B' },
                  { name: 'amount', label: 'Monthly fare (PKR)', type: 'number', required: true, step: '1', min: '1' },
                  { name: 'effectiveFrom', label: 'Effective from', type: 'date', required: true },
                ]}
              />
            </>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
