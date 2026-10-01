import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { currentRole, loose } from '@/lib/transport/rpc';
import { KeyForm } from './key-form';

export const dynamic = 'force-dynamic';

type Position = { vehicle_id: string; lat: number; lng: number; speed_kmh: number | null; pinged_at: string; updated_at: string; vehicle: { reg_no: string } | { reg_no: string }[] | null };
type Daily = { vehicle_id: string; day: string; distance_km: number; ping_count: number; max_speed_kmh: number | null; vehicle: { reg_no: string } | { reg_no: string }[] | null };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function LiveTrackingPage() {
  const supabase = loose(await supabaseServer());
  const role = await currentRole(supabase);
  const [{ data: features }, { data: positions }, { data: daily }] = await Promise.all([
    supabase.rpc('resolved_features'),
    supabase.from('transport_vehicle_position_latest').select('vehicle_id, lat, lng, speed_kmh, pinged_at, updated_at, vehicle:vehicle_id(reg_no)').order('pinged_at', { ascending: false }),
    supabase.from('transport_trip_distance_daily').select('vehicle_id, day, distance_km, ping_count, max_speed_kmh, vehicle:vehicle_id(reg_no)').order('day', { ascending: false }).limit(30),
  ]);
  const enabled = (features as Record<string, boolean> | null)?.transport_gps === true;
  const now = Date.now();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Live bus tracking</h1>
        <p className="text-sm text-muted-foreground">
          FR-P06 — a landing place for GPS pings so tracking can be switched on without reworking transport. Parents see only the bus on their child&apos;s route.
        </p>
        <p className="mt-2 text-sm" data-testid="gps-flag">
          Status: <Badge variant={enabled ? 'success' : 'outline'}>{enabled ? 'on' : 'off'}</Badge>
          {!enabled && <span className="ms-2 text-muted-foreground">While off, the ingest endpoint answers 404 and stores nothing. Ask your platform administrator to enable the transport_gps feature.</span>}
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Latest position of each vehicle</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="position-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Vehicle</th>
                <th>Last fix</th>
                <th>Speed</th>
                <th>Map</th>
              </tr>
            </thead>
            <tbody>
              {((positions ?? []) as Position[]).map((p) => {
                const age = Math.max(0, Math.round((now - Date.parse(p.pinged_at)) / 1000));
                return (
                  <tr key={p.vehicle_id} className="border-t" data-testid="position-row">
                    <td className="py-1">{one(p.vehicle)?.reg_no}</td>
                    <td>{age < 90 ? `${age}s ago` : `${Math.round(age / 60)} min ago`}</td>
                    <td>{p.speed_kmh ?? '-'} km/h</td>
                    <td>
                      <a className="underline" href={`https://www.openstreetmap.org/?mlat=${p.lat}&mlon=${p.lng}#map=16/${p.lat}/${p.lng}`} target="_blank" rel="noreferrer">
                        {Number(p.lat).toFixed(4)}, {Number(p.lng).toFixed(4)}
                      </a>
                    </td>
                  </tr>
                );
              })}
              {(positions ?? []).length === 0 && (
                <tr>
                  <td colSpan={4} className="py-2 text-muted-foreground">
                    No pings received yet.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Daily distance (kept after raw pings expire at 30 days)</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="distance-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Day (UTC)</th>
                <th>Vehicle</th>
                <th>Distance</th>
                <th>Pings</th>
                <th>Top speed</th>
              </tr>
            </thead>
            <tbody>
              {((daily ?? []) as Daily[]).map((d) => (
                <tr key={`${d.vehicle_id}-${d.day}`} className="border-t">
                  <td className="py-1">{d.day}</td>
                  <td>{one(d.vehicle)?.reg_no}</td>
                  <td>{d.distance_km} km</td>
                  <td>{d.ping_count}</td>
                  <td>{d.max_speed_kmh ?? '-'} km/h</td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>

      {['owner', 'super_admin', 'transport_manager', 'principal'].includes(role) && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Device keys</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p className="text-muted-foreground">
              Trackers or the vendor&apos;s cloud post batches of up to 100 pings to <code>/api/webhooks/transport/gps</code> with the key below in the <code>x-device-key</code> header (or an HMAC <code>x-signature</code> with <code>?tenant_id=</code>). Pings may arrive out of order; repeats are ignored.
            </p>
            <KeyForm />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
