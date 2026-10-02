import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { loose, pickCampus, todayPk } from '@/lib/transport/rpc';
import { BoardingSheet, type ManifestRow } from './boarding-sheet';
import { LegOpener } from './leg-opener';

export const dynamic = 'force-dynamic';

type Leg = { id: string; route_id: string; leg_type: 'pickup' | 'drop'; status: string; leg_date: string };

export default async function BoardingPage({ searchParams }: { searchParams: Promise<{ leg?: string; campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const campus = await pickCampus(supabase, sp.campus_id);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const today = todayPk();

  const [{ data: routes }, { data: legs }] = await Promise.all([
    supabase.from('transport_route').select('id, code, name').eq('campus_id', campus.id).eq('active', true).order('code'),
    supabase.from('transport_trip_leg').select('id, route_id, leg_type, status, leg_date').eq('leg_date', today).order('created_at'),
  ]);
  const routeRows = (routes ?? []) as { id: string; code: string; name: string }[];
  const legRows = (legs ?? []) as Leg[];
  const selected = legRows.find((l) => l.id === sp.leg);
  let manifest: ManifestRow[] = [];
  if (selected) {
    const { data } = await supabase.rpc('get_leg_manifest', { p_leg_id: selected.id });
    manifest = (data ?? []) as ManifestRow[];
  }
  const { data: counts } = legRows.length
    ? await supabase.from('transport_boarding_event').select('trip_leg_id, state').in('trip_leg_id', legRows.map((l) => l.id))
    : { data: [] as { trip_leg_id: string; state: string }[] };
  const tally = new Map<string, Record<string, number>>();
  for (const c of (counts ?? []) as { trip_leg_id: string; state: string }[]) {
    const t = tally.get(c.trip_leg_id) ?? {};
    t[c.state] = (t[c.state] ?? 0) + 1;
    tally.set(c.trip_leg_id, t);
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Boarding attendance</h1>
        <p className="text-sm text-muted-foreground">
          FR-P05 — open the trip, mark everyone boarded, tap the exceptions and submit once. Parents are told when their child boards or is dropped. A batch sent twice stores each student once.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Today&apos;s trips ({today})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm">
          <LegOpener routes={routeRows.map((r) => ({ id: r.id, label: `${r.code} · ${r.name}` }))} />
          <ul className="space-y-1" data-testid="leg-list">
            {legRows.map((l) => {
              const t = tally.get(l.id) ?? {};
              return (
                <li key={l.id} className="flex flex-wrap items-center gap-2" data-testid="leg-row">
                  <a className="font-medium hover:underline" href={`/transport/boarding?leg=${l.id}`}>
                    {routeRows.find((r) => r.id === l.route_id)?.code} · {l.leg_type}
                  </a>
                  <Badge variant={l.status === 'completed' ? 'success' : 'outline'}>{l.status}</Badge>
                  <span className="text-muted-foreground">
                    {t.boarded ?? 0} boarded · {t.dropped ?? 0} dropped · {t.absent ?? 0} absent
                  </span>
                </li>
              );
            })}
          </ul>
        </CardContent>
      </Card>

      {selected && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              {routeRows.find((r) => r.id === selected.route_id)?.code} · {selected.leg_type} manifest
            </CardTitle>
          </CardHeader>
          <CardContent>
            <BoardingSheet legId={selected.id} legType={selected.leg_type} rows={manifest} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
