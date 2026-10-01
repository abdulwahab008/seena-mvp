import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { currentRole, loose, pkr, TRANSPORT_STAFF } from '@/lib/transport/rpc';
import { addStop } from '../actions';
import { StopControls } from './stop-controls';

export const dynamic = 'force-dynamic';

type Stop = { id: string; seq: number; name: string; name_ur: string | null; pickup_time: string | null; drop_time: string | null; monthly_amount_paisa: number | null; slab_code: string | null };

export default async function RouteDetailPage({ params }: { params: Promise<{ routeId: string }> }) {
  const { routeId } = await params;
  const supabase = loose(await supabaseServer());
  const role = await currentRole(supabase);
  const { data: route } = await supabase.from('transport_route').select('id, campus_id, code, name, shift, active').eq('id', routeId).maybeSingle();
  if (!route) notFound();
  const [{ data: stops }, { data: slabs }] = await Promise.all([
    supabase.from('v_transport_route_sheet').select('stop_id, seq, stop_name, stop_name_ur, pickup_time, drop_time, monthly_amount_paisa, slab_code').eq('route_id', routeId).order('seq'),
    supabase.from('transport_fare_slab').select('id, code, name').eq('campus_id', route.campus_id).order('code'),
  ]);
  const rows: Stop[] = ((stops ?? []) as Record<string, unknown>[]).map((s) => ({
    id: s.stop_id as string, seq: s.seq as number, name: s.stop_name as string, name_ur: s.stop_name_ur as string | null,
    pickup_time: s.pickup_time as string | null, drop_time: s.drop_time as string | null,
    monthly_amount_paisa: s.monthly_amount_paisa as number | null, slab_code: s.slab_code as string | null,
  }));
  const canManage = TRANSPORT_STAFF.includes(role);
  const slabOptions = Array.from(new Map(((slabs ?? []) as { id: string; code: string; name: string }[]).map((s) => [s.code, s])).values()).map((s) => ({ value: s.id, label: `${s.code} · ${s.name}` }));

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">
            {route.code} · {route.name}
          </h1>
          <p className="text-sm text-muted-foreground">
            <Badge variant="outline">{route.shift}</Badge> {rows.length} stops. Move a stop to a new position and every sequence number renumbers in one step.
          </p>
        </div>
        <span className="flex gap-2 text-sm">
          <Link href="/transport/routes" className="rounded-md border px-3 py-1.5">
            All routes
          </Link>
          <Link href={`/transport/routes/${routeId}/sheet`} className="rounded-md border px-3 py-1.5" data-testid="route-sheet-link">
            Printable route sheet
          </Link>
        </span>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Stops in order</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="stop-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">#</th>
                <th>Stop</th>
                <th>Pickup</th>
                <th>Drop</th>
                <th>Fare</th>
                {canManage && <th>Order</th>}
              </tr>
            </thead>
            <tbody>
              {rows.map((s) => (
                <tr key={s.id} className="border-t" data-testid="stop-row">
                  <td className="py-1" data-testid="stop-seq">
                    {s.seq}
                  </td>
                  <td>
                    {s.name}
                    {s.name_ur && (
                      <span className="ms-2 text-muted-foreground" dir="rtl">
                        {s.name_ur}
                      </span>
                    )}
                  </td>
                  <td>{s.pickup_time?.slice(0, 5) ?? '-'}</td>
                  <td>{s.drop_time?.slice(0, 5) ?? '-'}</td>
                  <td>{s.slab_code ? `${s.slab_code} · ${pkr(s.monthly_amount_paisa)}` : '-'}</td>
                  {canManage && (
                    <td>
                      <StopControls routeId={routeId} stopId={s.id} seq={s.seq} count={rows.length} />
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>

      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add a stop</CardTitle>
          </CardHeader>
          <CardContent>
            <SpecForm
              testId="stop-form"
              submitLabel="Add stop"
              action={addStop}
              columns={4}
              fields={[
                { name: 'routeId', label: 'Route', type: 'hidden', defaultValue: routeId },
                { name: 'name', label: 'Stop name', required: true },
                { name: 'nameUr', label: 'Stop name (Urdu)', dir: 'rtl' },
                { name: 'pickupTime', label: 'Pickup time', type: 'time' },
                { name: 'dropTime', label: 'Drop time', type: 'time' },
                { name: 'fareSlabId', label: 'Fare slab', type: 'select', options: slabOptions },
                { name: 'lat', label: 'Latitude', type: 'number', step: 'any' },
                { name: 'lng', label: 'Longitude', type: 'number', step: 'any' },
                { name: 'seq', label: 'Position (blank = last)', type: 'number', min: '1' },
              ]}
            />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
