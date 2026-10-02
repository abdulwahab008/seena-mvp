import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { ActionForm } from '@/components/action-form';
import { acknowledgeCustodyAction, issueCustodyAction, returnCustodyAction } from './actions';
import { ClearanceChecker, RequestOtpButton } from './custody-widgets';

type SearchParams = { asof?: string };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function CustodyPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const asOf = /^\d{4}-\d{2}-\d{2}$/.test(sp.asof ?? '') ? (sp.asof as string) : '';
  const supabase = await supabaseServer();
  const [assetsRes, deptRes, roomRes, staffRes, openRes, asOfRes] = await Promise.all([
    supabase.from('asset').select('id, tag_no, name, status').in('status', ['active', 'in_repair']).order('tag_no'),
    supabase.from('department').select('id, name_en').order('name_en'),
    supabase.from('room').select('id, name').eq('is_active', true).order('name'),
    supabase.from('staff').select('id, full_name, employee_code, employment_status').neq('employment_status', 'exited').order('full_name'),
    supabase
      .from('asset_custody')
      .select('id, issued_on, acknowledged_at, ack_method, custodian_type, asset:asset_id(tag_no, name), department:department_id(name_en), room:room_id(name), staff:staff_id(full_name)')
      .is('returned_on', null)
      .order('issued_on', { ascending: false }),
    asOf ? supabase.rpc('v_asset_custody_asof', { p_date: asOf }) : Promise.resolve({ data: null }),
  ]);
  const staff = staffRes.data ?? [];
  const custodians = [
    ...(deptRes.data ?? []).map((d) => ({ value: `department:${d.id}`, label: `Department · ${d.name_en}` })),
    ...(roomRes.data ?? []).map((r) => ({ value: `room:${r.id}`, label: `Room · ${r.name}` })),
    ...staff.map((s) => ({ value: `staff:${s.id}`, label: `Staff · ${s.full_name}` })),
  ];
  const open = openRes.data ?? [];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Asset custody"
        description="FR-R04 — who holds each asset, and who held it on any past date. An asset can be in one custody at a time; an acknowledged issue cannot be edited; a staff exit is blocked while assets are outstanding."
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-base">In custody now</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="open-custody">
          {open.length === 0 && <p className="text-muted-foreground">Nothing is issued at the moment.</p>}
          {open.map((c) => (
            <div key={c.id} className="flex flex-wrap items-center justify-between gap-2 border-b py-2" data-testid="custody-row">
              <span>
                <span className="font-mono">{one(c.asset)?.tag_no}</span> {one(c.asset)?.name} → {one(c.department)?.name_en ?? one(c.room)?.name ?? one(c.staff)?.full_name}
                <span className="text-muted-foreground"> · since {c.issued_on}</span>
              </span>
              <span className="flex items-center gap-2">
                {c.acknowledged_at ? <Badge variant="success">Acknowledged by {c.ack_method}</Badge> : <><Badge variant="outline">Awaiting acknowledgement</Badge><RequestOtpButton custodyId={c.id} /></>}
              </span>
            </div>
          ))}
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Issue an asset</CardTitle>
          </CardHeader>
          <CardContent>
            <ActionForm
              testId="issue-form"
              submitLabel="Issue"
              action={issueCustodyAction}
              fields={[
                { name: 'assetId', label: 'Asset', type: 'select', required: true, options: (assetsRes.data ?? []).map((a) => ({ value: a.id, label: `${a.tag_no} · ${a.name}` })) },
                { name: 'custodian', label: 'Issue to', type: 'select', required: true, options: custodians },
                { name: 'issuedOn', label: 'Issued on', type: 'date' },
                { name: 'remarks', label: 'Remarks' },
              ]}
            />
          </CardContent>
        </Card>
        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Record a return</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm
                testId="return-form"
                submitLabel="Return"
                action={returnCustodyAction}
                fields={[
                  { name: 'custodyId', label: 'Custody', type: 'select', required: true, options: open.map((c) => ({ value: c.id, label: `${one(c.asset)?.tag_no} · ${one(c.asset)?.name}` })) },
                  { name: 'condition', label: 'Condition on return', type: 'select', required: true, options: ['good', 'fair', 'damaged', 'lost'].map((c) => ({ value: c, label: c })) },
                  { name: 'returnedOn', label: 'Returned on', type: 'date' },
                ]}
              />
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Acknowledge receipt</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm
                testId="ack-form"
                submitLabel="Acknowledge"
                action={acknowledgeCustodyAction}
                fields={[
                  { name: 'custodyId', label: 'Custody', type: 'select', required: true, options: open.filter((c) => !c.acknowledged_at).map((c) => ({ value: c.id, label: `${one(c.asset)?.tag_no} · ${one(c.asset)?.name}` })) },
                  { name: 'method', label: 'Method', type: 'select', required: true, defaultValue: 'otp', options: [{ value: 'otp', label: 'OTP' }, { value: 'signature', label: 'Signature' }, { value: 'paper', label: 'Paper register' }] },
                  { name: 'otp', label: '6-digit code (OTP)' },
                  { name: 'reference', label: 'Form / register reference' },
                ]}
              />
            </CardContent>
          </Card>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Who held it on a date</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          <form method="get" className="flex items-end gap-2">
            <label className="space-y-1">
              <span className="block text-muted-foreground">As at</span>
              <input type="date" name="asof" defaultValue={asOf} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <button type="submit" className="h-9 rounded-md border px-3" data-testid="asof-show">
              Show
            </button>
          </form>
          {asOf && (
            <div data-testid="asof-result">
              {((asOfRes.data as { asset_id: string; tag_no: string; asset_name: string; custodian_name: string }[] | null) ?? []).map((r) => (
                <p key={r.asset_id} data-testid="asof-row">
                  <span className="font-mono">{r.tag_no}</span> {r.asset_name} — {r.custodian_name}
                </p>
              ))}
              {((asOfRes.data as unknown[] | null) ?? []).length === 0 && <p className="text-muted-foreground">No assets were in custody on {asOf}.</p>}
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Exit clearance</CardTitle>
        </CardHeader>
        <CardContent>
          <ClearanceChecker staff={staff.map((s) => ({ id: s.id, label: `${s.full_name} (${s.employee_code})` }))} />
        </CardContent>
      </Card>
    </div>
  );
}
