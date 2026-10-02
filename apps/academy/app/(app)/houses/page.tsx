import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AutoAssignPanel, DeleteHouseButton, HouseForm, MoveForm, PointsForm } from './house-forms';

type SearchParams = { from?: string; to?: string };
const isoDate = /^\d{4}-\d{2}-\d{2}$/;

export default async function HousesPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  const from = isoDate.test(sp.from ?? '') ? (sp.from as string) : `${today.slice(0, 4)}-01-01`;
  const to = isoDate.test(sp.to ?? '') ? (sp.to as string) : today;
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;
  const { data: sessions } = await supabase.from('academic_session').select('id, is_current').order('starts_on', { ascending: false });
  const sessionId = sessions?.find((s) => s.is_current)?.id ?? sessions?.[0]?.id;

  const [{ data: houses }, { data: setting }, { data: standings }, { count: unhousedCount }] = await Promise.all([
    supabase.from('house').select('id, name, colour_hex, motto').order('name'),
    campusId ? supabase.from('house_setting').select('capacity_balancing').eq('campus_id', campusId).maybeSingle() : Promise.resolve({ data: null }),
    campusId ? supabase.rpc('house_standings', { p_campus_id: campusId, p_from: from, p_to: to }) : Promise.resolve({ data: [] }),
    supabase.from('student').select('id', { count: 'exact', head: true }).is('house_id', null).eq('status', 'active'),
  ]);
  const rows = standings ?? [];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Houses</h1>
        <p className="text-sm text-muted-foreground">
          FR-C06 — students are allotted to houses with siblings kept together, then the least-populated house. Moves are date-effective: points stay with the house the student was in on the day they were earned.
        </p>
      </div>

      {campusId && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">New house</CardTitle>
          </CardHeader>
          <CardContent>
            <HouseForm campusId={campusId} />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Standings, {from} to {to}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          <form method="get" className="flex flex-wrap items-end gap-3">
            <label className="space-y-1">
              <span className="block text-muted-foreground">From</span>
              <input type="date" name="from" defaultValue={from} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <label className="space-y-1">
              <span className="block text-muted-foreground">To</span>
              <input type="date" name="to" defaultValue={to} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <button type="submit" className="h-9 rounded-md border px-3">
              Show
            </button>
          </form>
          <table className="w-full text-left" data-testid="house-table">
            <thead>
              <tr className="border-b text-muted-foreground">
                <th className="py-1">House</th>
                <th>Members</th>
                <th>Points</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {(houses ?? []).length === 0 && (
                <tr>
                  <td colSpan={4} className="py-2 text-muted-foreground">
                    No houses yet.
                  </td>
                </tr>
              )}
              {(houses ?? []).map((h) => {
                const s = rows.find((r) => r.house_id === h.id);
                return (
                  <tr key={h.id} className="border-b" data-testid="house-row">
                    <td className="py-2">
                      <span className="mr-2 inline-block h-3 w-3 rounded-full align-middle" style={{ backgroundColor: h.colour_hex }} />
                      {h.name}
                      {h.motto && <span className="ml-2 text-xs text-muted-foreground">{h.motto}</span>}
                    </td>
                    <td data-testid="house-members">{s?.members ?? 0}</td>
                    <td data-testid="house-points">{s?.points ?? 0}</td>
                    <td className="text-right">
                      <DeleteHouseButton houseId={h.id} />
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </CardContent>
      </Card>

      {campusId && sessionId && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Auto-assign ({unhousedCount ?? 0} students without a house)</CardTitle>
          </CardHeader>
          <CardContent>
            <AutoAssignPanel campusId={campusId} sessionId={sessionId} balancing={setting?.capacity_balancing ?? true} />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Move a student</CardTitle>
        </CardHeader>
        <CardContent>
          <MoveForm houses={(houses ?? []).map((h) => ({ id: h.id, name: h.name }))} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Record house points</CardTitle>
        </CardHeader>
        <CardContent>
          <PointsForm />
        </CardContent>
      </Card>
    </div>
  );
}
