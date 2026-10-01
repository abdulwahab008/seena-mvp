import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ActionButton, SpecForm } from '@/components/spec-form';
import { loose, pickCampus, todayPk } from '@/lib/transport/rpc';
import { decideAway, recordAway } from './actions';
import { MenuEditor, type MenuSlot } from './menu-editor';

export const dynamic = 'force-dynamic';

type Off = {
  id: string; starts_on: string; ends_on: string; status: string; reason: string | null;
  student: { name_en: string; gr_number: string } | { name_en: string; gr_number: string }[] | null;
};
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

function mondayOf(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}

export default async function MessPage({ searchParams }: { searchParams: Promise<{ week?: string; campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const campus = await pickCampus(supabase, sp.campus_id);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const week = mondayOf(/^\d{4}-\d{2}-\d{2}$/.test(sp.week ?? '') ? (sp.week as string) : todayPk());

  const [{ data: menu }, { data: offs }] = await Promise.all([
    supabase.from('hostel_mess_menu').select('day_of_week, meal, items, items_ur, published_at').eq('campus_id', campus.id).eq('week_start', week),
    supabase
      .from('hostel_mess_off')
      .select('id, starts_on, ends_on, status, reason, student:student_id(name_en, gr_number)')
      .eq('campus_id', campus.id)
      .gte('ends_on', todayPk())
      .order('starts_on'),
  ]);
  const slots = ((menu ?? []) as { day_of_week: number; meal: MenuSlot['meal']; items: string; items_ur: string | null; published_at: string | null }[]).map((m) => ({
    day: m.day_of_week, meal: m.meal, items: m.items, items_ur: m.items_ur ?? '',
  }));
  const publishedAt = ((menu ?? []) as { published_at: string | null }[]).find((m) => m.published_at)?.published_at ?? null;
  const rows = (offs ?? []) as Off[];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Mess menu and mess-off</h1>
        <p className="text-sm text-muted-foreground">FR-Q05 — publish the weekly menu (all 21 meals) and manage the days boarders are away. Approved mess-off days come off the mess charge.</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Week of {week}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <form method="get" className="flex items-end gap-3 text-sm">
            <label className="space-y-1">
              <span className="block text-muted-foreground">Week containing</span>
              <input type="date" name="week" defaultValue={week} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <button type="submit" className="h-9 rounded-md border px-3">
              Show
            </button>
            {publishedAt ? <Badge variant="success">published {new Date(publishedAt).toLocaleString('en-GB', { timeZone: 'Asia/Karachi' })}</Badge> : <Badge variant="outline">draft</Badge>}
          </form>
          <MenuEditor key={week + String(!!publishedAt)} campusId={campus.id} weekStart={week} initial={slots} published={!!publishedAt} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Mess-off requests and away periods</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm">
          <table className="w-full" data-testid="mess-off-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Student</th>
                <th>From</th>
                <th>To</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {rows.map((o) => (
                <tr key={o.id} className="border-t" data-testid="mess-off-row">
                  <td className="py-1">
                    {one(o.student)?.name_en} <span className="text-muted-foreground">({one(o.student)?.gr_number})</span>
                  </td>
                  <td>{o.starts_on}</td>
                  <td>{o.ends_on}</td>
                  <td>
                    <Badge variant={o.status === 'approved' ? 'success' : o.status === 'pending' ? 'warning' : 'outline'}>{o.status}</Badge>
                  </td>
                  <td className="space-x-1">
                    {o.status === 'pending' && (
                      <>
                        <ActionButton label="Approve" testId={`approve-${one(o.student)?.gr_number}`} action={decideAway} args={[o.id, true]} />
                        <ActionButton label="Reject" variant="ghost" action={decideAway} args={[o.id, false]} />
                      </>
                    )}
                  </td>
                </tr>
              ))}
              {rows.length === 0 && (
                <tr>
                  <td colSpan={5} className="py-2 text-muted-foreground">
                    No current or upcoming mess-off.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
          <SpecForm
            testId="away-form"
            submitLabel="Record away period"
            action={recordAway}
            columns={4}
            fields={[
              { name: 'grNumber', label: 'Student GR number', required: true },
              { name: 'from', label: 'First day away', type: 'date', required: true },
              { name: 'to', label: 'Last day away', type: 'date', required: true },
              { name: 'reason', label: 'Reason' },
            ]}
          />
        </CardContent>
      </Card>
    </div>
  );
}
