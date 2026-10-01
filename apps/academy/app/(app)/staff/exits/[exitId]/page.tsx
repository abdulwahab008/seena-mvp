import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, one } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ClearButton, CompleteExitForm, WaiveForm } from '../exit-forms';

export const dynamic = 'force-dynamic';

export default async function StaffExitPage({ params }: { params: Promise<{ exitId: string }> }) {
  const { exitId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(exitId)) notFound();
  const actor = await getCurrentActor();
  const supabase = await supabaseServer();
  const { data: exit } = await supabase
    .from('staff_exit')
    .select('id, staff_id, exit_type, notice_date, last_working_date, notice_period_days, notice_shortfall_days, status, reason, completed_at, staff:staff_id(full_name, employee_code)')
    .eq('id', exitId)
    .maybeSingle();
  if (!exit) notFound();
  const { data: items } = await supabase
    .from('staff_clearance_item')
    .select('item_code, item_name, owner_role, is_mandatory, cleared_at, waiver_reason, waived_at, sort_order')
    .eq('exit_id', exitId)
    .order('sort_order');
  const staff = one(exit.staff);
  const canHr = isHrWriter(actor?.role);
  const open = exit.status !== 'completed';
  const outstanding = (items ?? []).filter((i) => i.is_mandatory && !i.cleared_at && !i.waived_at);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold" data-testid="exit-staff">
            Exit: {staff?.full_name}
          </h1>
          <p className="text-sm text-muted-foreground">
            {staff?.employee_code} · {exit.exit_type.replace('_', ' ')} · last working date {exit.last_working_date}
            {exit.notice_date ? ` · notice given ${exit.notice_date}` : ''}
          </p>
          <p className="text-sm">
            <Link href={`/staff/${exit.staff_id}`} className="underline">
              Staff profile
            </Link>
          </p>
        </div>
        <Badge variant={open ? 'warning' : 'success'} data-testid="exit-status">
          {exit.status}
        </Badge>
      </div>

      {exit.notice_shortfall_days > 0 && (
        <div className="rounded-md border border-warning bg-warning-muted p-3 text-sm" data-testid="notice-shortfall">
          Notice shortfall: {exit.notice_shortfall_days} day(s) against a contractual notice of {exit.notice_period_days} day(s). It is carried into the final settlement.
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Clearance checklist</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="clearance-list">
          {(items ?? []).map((i) => {
            const done = !!i.cleared_at;
            const waived = !!i.waived_at;
            const mine = actor?.role === i.owner_role;
            return (
              <div key={i.item_code} className="flex flex-wrap items-center justify-between gap-2 border-b pb-3" data-testid={`clearance-${i.item_code}`}>
                <div>
                  <p className="font-medium">{i.item_name}</p>
                  <p className="text-xs text-muted-foreground">
                    Owner: {i.owner_role.replace('_', ' ')}
                    {done && i.cleared_at ? ` · cleared ${new Date(i.cleared_at).toLocaleDateString('en-PK', { timeZone: 'Asia/Karachi' })}` : ''}
                    {waived ? ` · waived: ${i.waiver_reason}` : ''}
                  </p>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  {done && <Badge variant="success">cleared</Badge>}
                  {waived && <Badge variant="info">waived</Badge>}
                  {!done && !waived && <Badge variant="warning">outstanding</Badge>}
                  {open && !done && mine && <ClearButton exitId={exitId} itemCode={i.item_code} />}
                  {open && !done && !waived && canHr && <WaiveForm exitId={exitId} itemCode={i.item_code} />}
                </div>
              </div>
            );
          })}
        </CardContent>
      </Card>

      {open && canHr && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Complete the exit</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <p className="text-muted-foreground">
              {outstanding.length === 0 ? 'Every mandatory item is cleared or waived.' : `${outstanding.length} item(s) still outstanding: ${outstanding.map((o) => o.item_name).join(', ')}.`} Completing the exit marks the person as having left and signs them out everywhere; it cannot be done before the last working date.
            </p>
            <CompleteExitForm exitId={exitId} />
          </CardContent>
        </Card>
      )}
      {!open && exit.completed_at && <p className="text-sm text-muted-foreground">Completed {new Date(exit.completed_at).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}. Access was revoked at that moment.</p>}
    </div>
  );
}
