import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { ActionForm } from '@/components/action-form';
import { pkr } from '@/lib/rpc-action';
import { createVendorAction, logMaintenanceAction, setThresholdAction } from './actions';
import { CloseRepairButton } from './close-button';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function MaintenancePage() {
  const supabase = await supabaseServer();
  const [assets, vendors, users, repairs, reminders, setting] = await Promise.all([
    supabase.from('asset').select('id, tag_no, name, status').neq('status', 'disposed').neq('status', 'written_off').order('tag_no'),
    supabase.from('procurement_vendor').select('id, name').eq('active', true).order('name'),
    supabase.from('app_user').select('user_id, full_name, app_role').order('full_name'),
    supabase
      .from('asset_maintenance')
      .select('id, reported_on, fault, cost, is_capitalised, downtime_from, downtime_to, next_service_due, closed_at, asset:asset_id(tag_no, name), vendor:vendor_id(name)')
      .order('reported_on', { ascending: false })
      .limit(60),
    supabase.from('asset_service_reminder').select('id, due_on, recipient_role, asset:asset_id(tag_no, name)').order('created_at', { ascending: false }).limit(20),
    supabase.from('asset_setting').select('capitalisation_threshold').maybeSingle(),
  ]);
  const threshold = Number(setting.data?.capitalisation_threshold ?? 5000000);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Maintenance and repairs"
        description="FR-R05 — one repair log for buses, generators and everything else. Downtime makes an asset unavailable: a bus in the workshop cannot be assigned to a trip. Repairs flagged as capital improvements above the threshold raise the asset's cost and re-base its depreciation."
      />

      {(reminders.data ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Service reminders</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm" data-testid="service-reminders">
            {(reminders.data ?? []).map((r) => (
              <p key={r.id}>
                {one(r.asset)?.tag_no} {one(r.asset)?.name} is due for service on {r.due_on}.
              </p>
            ))}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Repair log</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="repair-log">
          {(repairs.data ?? []).length === 0 && <p className="text-muted-foreground">No repairs logged yet.</p>}
          {(repairs.data ?? []).map((m) => (
            <div key={m.id} className="flex flex-wrap items-center justify-between gap-2 border-b py-2" data-testid="repair-row">
              <span>
                <span className="font-mono">{one(m.asset)?.tag_no}</span> {m.fault} · {pkr(m.cost)}
                {m.is_capitalised ? ' (capital improvement)' : ''}
                {one(m.vendor)?.name ? ` · ${one(m.vendor)?.name}` : ''}
                {m.downtime_from ? ` · down ${m.downtime_from} to ${m.downtime_to ?? 'open'}` : ''}
                {m.next_service_due ? ` · next service ${m.next_service_due}` : ''}
              </span>
              {m.closed_at ? <Badge variant="outline">Closed</Badge> : <CloseRepairButton maintenanceId={m.id} />}
            </div>
          ))}
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Log a repair or service</CardTitle>
          </CardHeader>
          <CardContent>
            <ActionForm
              testId="maintenance-form"
              submitLabel="Log repair"
              action={logMaintenanceAction}
              fields={[
                { name: 'assetId', label: 'Asset', type: 'select', required: true, options: (assets.data ?? []).map((a) => ({ value: a.id, label: `${a.tag_no} · ${a.name}` })) },
                { name: 'fault', label: 'Fault or work done', type: 'textarea' },
                { name: 'vendorId', label: 'Vendor', type: 'select', options: (vendors.data ?? []).map((v) => ({ value: v.id, label: v.name })) },
                { name: 'costPkr', label: 'Cost (PKR)', type: 'number', defaultValue: '0' },
                { name: 'isCapitalised', label: `Capital improvement (above PKR ${(threshold / 100).toLocaleString('en-PK')})`, type: 'checkbox' },
                { name: 'downtimeFrom', label: 'Downtime from', type: 'date' },
                { name: 'downtimeTo', label: 'Downtime to', type: 'date' },
                { name: 'nextServiceDue', label: 'Next service due', type: 'date' },
                { name: 'responsibleUserId', label: 'Maintenance owner', type: 'select', options: (users.data ?? []).map((u) => ({ value: u.user_id, label: `${u.full_name} (${u.app_role})` })) },
              ]}
            />
          </CardContent>
        </Card>
        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Add a vendor</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm testId="vendor-form" submitLabel="Add vendor" action={createVendorAction} fields={[{ name: 'name', label: 'Vendor name' }, { name: 'phone', label: 'Phone' }]} />
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Capitalisation threshold</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm
                testId="threshold-form"
                submitLabel="Save threshold"
                action={setThresholdAction}
                resetOnSuccess={false}
                fields={[{ name: 'thresholdPkr', label: 'Repairs above this amount (PKR) may be capitalised', type: 'number', defaultValue: String(threshold / 100) }]}
              />
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}
