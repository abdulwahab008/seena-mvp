import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export const dynamic = 'force-dynamic';

const STATUS_VARIANT: Record<string, 'info' | 'warning' | 'success'> = { initiated: 'info', clearance: 'warning', completed: 'success' };

export default async function StaffExitsPage() {
  const actor = await getCurrentActor();
  const supabase = await supabaseServer();
  const { data: exits } = await supabase
    .from('staff_exit')
    .select('id, exit_type, last_working_date, notice_shortfall_days, status, initiated_at, staff:staff_id(full_name, employee_code), items:staff_clearance_item(item_code, item_name, owner_role, is_mandatory, cleared_at, waived_at)')
    .order('initiated_at', { ascending: false })
    .limit(100);

  type Item = { item_code: string; item_name: string; owner_role: string; is_mandatory: boolean; cleared_at: string | null; waived_at: string | null };
  const rows = (exits ?? []).map((e) => {
    const items = (e.items ?? []) as Item[];
    return { ...e, staff: one(e.staff), items, outstanding: items.filter((i) => i.is_mandatory && !i.cleared_at && !i.waived_at) };
  });
  const mine = rows.filter((e) => e.status !== 'completed').flatMap((e) => e.outstanding.filter((i) => i.owner_role === actor?.role).map((i) => ({ exit: e, item: i })));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff exits</h1>
        <p className="text-sm text-muted-foreground">
          FR-D16 — an exit completes only when every department has signed off (or HR has recorded a waiver with a reason). Completing it revokes the person&apos;s access immediately; their record is kept.
          Start an exit from the person&apos;s profile.
        </p>
      </div>

      {mine.length > 0 && (
        <Card data-testid="my-clearance">
          <CardHeader>
            <CardTitle className="text-base">Waiting for your department</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            {mine.map(({ exit, item }) => (
              <div key={`${exit.id}-${item.item_code}`} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2">
                <span>
                  {exit.staff?.full_name} — {item.item_name}
                </span>
                <Link href={`/staff/exits/${exit.id}`} className="text-primary underline">
                  Open
                </Link>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">All exits</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="exit-list">
          {rows.length === 0 && <p className="text-muted-foreground">No exits yet.</p>}
          {rows.map((e) => (
            <div key={e.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="exit-row">
              <span>
                <Link href={`/staff/exits/${e.id}`} className="font-medium underline">
                  {e.staff?.full_name}
                </Link>{' '}
                <span className="text-xs text-muted-foreground">
                  {e.exit_type.replace('_', ' ')} · last day {e.last_working_date}
                  {e.notice_shortfall_days > 0 ? ` · notice short by ${e.notice_shortfall_days} day(s)` : ''}
                </span>
              </span>
              <span className="flex items-center gap-2">
                {e.status !== 'completed' && <span className="text-xs text-muted-foreground">{e.outstanding.length} item(s) outstanding</span>}
                <Badge variant={STATUS_VARIANT[e.status] ?? 'outline'}>{e.status}</Badge>
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
