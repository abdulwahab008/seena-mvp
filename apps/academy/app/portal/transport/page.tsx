import { supabaseServer } from '@/lib/supabase/server';
import { getLang } from '@/lib/i18n/server';
import { t } from '@/lib/i18n/messages';
import { loose, todayPk } from '@/lib/transport/rpc';
import { PositionPanel } from './position-panel';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { requestTransportChange } from './actions';

export const dynamic = 'force-dynamic';

type Alloc = {
  id: string; student_id: string; route_id: string; pickup_stop_id: string; drop_stop_id: string; starts_on: string;
  student: { name_en: string; name_ur: string | null } | { name_en: string; name_ur: string | null }[] | null;
};
type Stop = { route_id: string; stop_id: string; seq: number; stop_name: string; stop_name_ur: string | null; pickup_time: string | null; drop_time: string | null; route_code: string; route_name: string };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

// FR-P01 / FR-P04: the parent sees the route their child rides, every stop in
// order with pickup and drop times, and their own stop highlighted. RLS limits
// the rows to routes the child is allocated to.
export default async function PortalTransportPage() {
  const lang = await getLang();
  const supabase = loose(await supabaseServer());
  const today = todayPk();
  const { data: allocs } = await supabase
    .from('transport_allocation')
    .select('id, student_id, route_id, pickup_stop_id, drop_stop_id, starts_on, student:student_id(name_en, name_ur)')
    .or(`ends_on.is.null,ends_on.gte.${today}`)
    .order('starts_on');
  const rows = (allocs ?? []) as Alloc[];
  const routeIds = [...new Set(rows.map((a) => a.route_id))];
  const { data: stops } = routeIds.length
    ? await supabase.from('v_transport_route_sheet').select('route_id, stop_id, seq, stop_name, stop_name_ur, pickup_time, drop_time, route_code, route_name').in('route_id', routeIds).order('seq')
    : { data: [] as Stop[] };
  const stopRows = (stops ?? []) as Stop[];
  const { data: events } = await supabase
    .from('transport_boarding_event')
    .select('id, student_id, state, marked_at, trip_leg:trip_leg_id(leg_type, leg_date)')
    .gte('marked_at', `${today}T00:00:00+05:00`)
    .order('marked_at');
  type Ev = { id: string; student_id: string; state: string; marked_at: string };
  const eventRows = (events ?? []) as Ev[];
  const stateText = (st: string) => (st === 'boarded' ? t(lang, 'transport.boarded') : st === 'dropped' ? t(lang, 'transport.dropped') : t(lang, 'transport.absent'));
  const clock = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi' });
  const { data: live } = await supabase.from('transport_vehicle_position_latest').select('vehicle_id, lat, lng, speed_kmh, pinged_at');
  const hhmm = (v: string | null) => v?.slice(0, 5) ?? '-';
  const stopName = (s: Stop) => (lang === 'ur' && s.stop_name_ur ? s.stop_name_ur : s.stop_name);
  const typed = await supabaseServer();
  const [{ data: children }, { data: requests }] = await Promise.all([
    typed.from('student').select('id, name_en, name_ur').is('deleted_at', null).order('name_en'),
    typed.from('transport_request').select('id, kind, status, decision_note, created_at, student:student_id(name_en, name_ur)').order('created_at', { ascending: false }).limit(10),
  ]);
  const kindLabel = { start: t(lang, 'transport.request.start'), stop: t(lang, 'transport.request.stop'), change_route: t(lang, 'transport.request.changeRoute'), change_stop: t(lang, 'transport.request.changeStop') } as const;
  const statusLabel = { pending: t(lang, 'transport.request.pending'), approved: t(lang, 'transport.request.approved'), rejected: t(lang, 'transport.request.rejected') } as const;
  const childName = (c: { name_en: string; name_ur: string | null } | null) => (lang === 'ur' && c?.name_ur ? c.name_ur : (c?.name_en ?? ''));

  return (
    <div className="space-y-6">
      <h2 className="text-xl font-semibold">{t(lang, 'transport.title')}</h2>
      <PositionPanel initial={(live ?? []) as { vehicle_id: string; lat: number; lng: number; speed_kmh: number | null; pinged_at: string }[]} lang={lang} />
      {rows.length === 0 && <p className="text-sm text-muted-foreground">{t(lang, 'transport.none')}</p>}
      {rows.map((a) => {
        const routeStops = stopRows.filter((s) => s.route_id === a.route_id);
        const student = one(a.student);
        const head = routeStops[0];
        return (
          <Card key={a.id} data-testid="portal-transport-card">
            <CardHeader>
              <CardTitle className="text-base">
                {lang === 'ur' && student?.name_ur ? student.name_ur : student?.name_en} · {t(lang, 'transport.route')} {head?.route_code} {head?.route_name}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              <ul className="space-y-1" data-testid="boarding-today">
                {eventRows.filter((e) => e.student_id === a.student_id).map((e) => (
                  <li key={e.id}>
                    {stateText(e.state)} · {clock(e.marked_at)}
                  </li>
                ))}
              </ul>
              <table className="w-full">
                <thead>
                  <tr className="text-start text-muted-foreground">
                    <th className="py-1 text-start">#</th>
                    <th className="text-start">{t(lang, 'transport.stop')}</th>
                    <th className="text-start">{t(lang, 'transport.pickup')}</th>
                    <th className="text-start">{t(lang, 'transport.drop')}</th>
                  </tr>
                </thead>
                <tbody>
                  {routeStops.map((s) => (
                    <tr key={s.stop_id} className={`border-t ${s.stop_id === a.pickup_stop_id ? 'bg-muted/50 font-medium' : ''}`} data-testid="portal-stop-row">
                      <td className="py-1">{s.seq}</td>
                      <td>
                        {stopName(s)}
                        {s.stop_id === a.pickup_stop_id && <span className="ms-2 text-xs text-muted-foreground">{t(lang, 'transport.yourStop')}</span>}
                      </td>
                      <td>{hhmm(s.pickup_time)}</td>
                      <td>{hhmm(s.drop_time)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </CardContent>
          </Card>
        );
      })}
      {(children ?? []).length > 0 && (
        <Card data-testid="transport-request-card">
          <CardHeader>
            <CardTitle className="text-base">{t(lang, 'transport.request.title')}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <SpecForm
              testId="transport-request-form"
              submitLabel={t(lang, 'transport.request.submit')}
              action={requestTransportChange}
              columns={3}
              fields={[
                { name: 'studentId', label: t(lang, 'transport.request.child'), type: 'select', required: true, defaultValue: children?.[0]?.id, options: (children ?? []).map((c) => ({ value: c.id, label: childName(c) })) },
                { name: 'kind', label: t(lang, 'transport.request.kind'), type: 'select', required: true, options: Object.entries(kindLabel).map(([value, label]) => ({ value, label })) },
                { name: 'note', label: t(lang, 'transport.request.note') },
              ]}
            />
            {(requests ?? []).length > 0 && (
              <div className="space-y-1">
                <p className="font-medium">{t(lang, 'transport.request.mine')}</p>
                <ul className="space-y-1" data-testid="my-transport-requests">
                  {(requests ?? []).map((r) => (
                    <li key={r.id}>
                      {childName(one(r.student))} · {kindLabel[r.kind as keyof typeof kindLabel] ?? r.kind} · {statusLabel[r.status as keyof typeof statusLabel] ?? r.status}
                      {r.decision_note ? ` · ${r.decision_note}` : ''}
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
