import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { currentRole, loose, pickCampus, todayPk, TRANSPORT_STAFF } from '@/lib/transport/rpc';
import { saveVehicle, setTokenTaxPolicy } from './actions';
import { DocumentForm } from './document-form';

export const dynamic = 'force-dynamic';

type Vehicle = { id: string; reg_no: string; make: string | null; model: string | null; seat_capacity: number; fuel: string; ownership: string; active: boolean };
type Doc = { id: string; vehicle_id: string; doc_type: string; doc_no: string | null; expires_on: string; mandatory: boolean };

const LABEL: Record<string, string> = { fitness: 'Fitness', token_tax: 'Token tax', insurance: 'Insurance', permit: 'Permit' };

function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000);
}

export default async function FleetPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const canManage = TRANSPORT_STAFF.includes(role);
  const today = todayPk();

  const [{ data: vehicles }, { data: docs }, { data: appUser }, { data: setting }] = await Promise.all([
    supabase.from('transport_vehicle').select('id, reg_no, make, model, seat_capacity, fuel, ownership, active').eq('campus_id', campus.id).order('reg_no'),
    supabase.from('transport_vehicle_document').select('id, vehicle_id, doc_type, doc_no, expires_on, mandatory').eq('campus_id', campus.id).order('expires_on', { ascending: false }),
    supabase.from('app_user').select('tenant_id').maybeSingle(),
    supabase.from('tenant_setting').select('value').eq('key', 'transport.token_tax_mandatory_for_contracted').maybeSingle(),
  ]);
  const tokenTaxMandatory = (setting as { value: unknown } | null)?.value !== false;
  const byVehicle = new Map<string, Map<string, Doc>>();
  for (const d of (docs ?? []) as Doc[]) {
    const m = byVehicle.get(d.vehicle_id) ?? new Map<string, Doc>();
    if (!m.has(d.doc_type)) m.set(d.doc_type, d); // newest expiry first: the latest document wins
    byVehicle.set(d.vehicle_id, m);
  }
  const list = (vehicles ?? []) as Vehicle[];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Fleet and vehicle documents</h1>
        <p className="text-sm text-muted-foreground">
          FR-P02 — a bus whose fitness certificate (or other enforced document) has expired cannot be assigned to a route. Only a Principal can override, with a recorded reason.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Vehicles</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm" data-testid="vehicle-list">
          {list.length === 0 && <p className="text-muted-foreground">No vehicles registered yet.</p>}
          {list.map((v) => {
            const docMap = byVehicle.get(v.id) ?? new Map<string, Doc>();
            return (
              <div key={v.id} className="space-y-1 border-b pb-3" data-testid="vehicle-row">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-medium">
                    {v.reg_no} · {[v.make, v.model].filter(Boolean).join(' ') || 'vehicle'} · {v.seat_capacity} seats
                  </span>
                  <span className="flex gap-2">
                    <Badge variant="outline">{v.fuel}</Badge>
                    <Badge variant="outline">{v.ownership}</Badge>
                    {!v.active && <Badge variant="warning">inactive</Badge>}
                  </span>
                </div>
                <div className="flex flex-wrap gap-2">
                  {['fitness', 'token_tax', 'insurance', 'permit'].map((t) => {
                    const d = docMap.get(t);
                    if (!d) return t === 'permit' ? null : <Badge key={t} variant="warning">{LABEL[t]}: not on file</Badge>;
                    const left = daysBetween(today, d.expires_on);
                    const variant = !d.mandatory ? 'outline' : left < 0 ? 'destructive' : left <= 30 ? 'warning' : 'success';
                    return (
                      <Badge key={t} variant={variant} data-testid={`doc-${t}`}>
                        {LABEL[t]}: {d.expires_on}
                        {left < 0 ? ` (expired ${-left} d ago)` : left <= 30 ? ` (${left} d left)` : ''}
                      </Badge>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </CardContent>
      </Card>

      {canManage && (
        <>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Register a vehicle</CardTitle>
            </CardHeader>
            <CardContent>
              <SpecForm
                testId="vehicle-form"
                submitLabel="Register vehicle"
                action={saveVehicle}
                columns={4}
                fields={[
                  { name: 'campusId', label: 'Campus', type: 'hidden', defaultValue: campus.id },
                  { name: 'regNo', label: 'Registration no.', required: true, placeholder: 'LEB-1234' },
                  { name: 'make', label: 'Make' },
                  { name: 'model', label: 'Model' },
                  { name: 'seatCapacity', label: 'Seats', type: 'number', required: true, min: '1' },
                  { name: 'fuel', label: 'Fuel', type: 'select', required: true, defaultValue: 'diesel', options: ['diesel', 'petrol', 'cng', 'lpg', 'hybrid', 'electric'].map((f) => ({ value: f, label: f })) },
                  { name: 'ownership', label: 'Ownership', type: 'select', required: true, defaultValue: 'owned', options: [{ value: 'owned', label: 'Owned' }, { value: 'contracted', label: 'Contracted' }] },
                  { name: 'active', label: 'Active', type: 'checkbox', defaultValue: 'true' },
                ]}
              />
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Record a document</CardTitle>
            </CardHeader>
            <CardContent>
              <DocumentForm tenantId={(appUser as { tenant_id: string } | null)?.tenant_id ?? ''} vehicles={list.map((v) => ({ id: v.id, label: v.reg_no }))} />
            </CardContent>
          </Card>
        </>
      )}
      {['owner', 'super_admin', 'principal'].includes(role) && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Token tax for contracted vehicles</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p className="text-muted-foreground">Currently {tokenTaxMandatory ? 'required' : 'not required'} before a contracted vehicle can be assigned.</p>
            <SpecForm
              testId="token-tax-form"
              submitLabel="Save policy"
              action={setTokenTaxPolicy}
              resetOnSuccess={false}
              columns={1}
              fields={[{ name: 'mandatory', label: 'Token tax is mandatory for contracted vehicles', type: 'checkbox', defaultValue: String(tokenTaxMandatory) }]}
            />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
