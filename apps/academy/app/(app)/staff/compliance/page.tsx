import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, todayKarachi } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AddDocumentForm, RenewForm, RunCheckButton } from './compliance-forms';

export const dynamic = 'force-dynamic';

const STATUS_LABEL: Record<string, string> = { compliant: 'Compliant', non_compliant: 'Non-compliant', incomplete: 'Incomplete' };
const STATUS_VARIANT: Record<string, 'success' | 'destructive' | 'warning'> = { compliant: 'success', non_compliant: 'destructive', incomplete: 'warning' };

function daysUntil(iso: string, today: string): number {
  return Math.round((new Date(`${iso}T00:00:00Z`).getTime() - new Date(`${today}T00:00:00Z`).getTime()) / 86_400_000);
}

export default async function StaffCompliancePage() {
  const actor = await getCurrentActor();
  const supabase = await supabaseServer();
  const today = todayKarachi();
  const canWrite = isHrWriter(actor?.role);

  const [{ data: compliance }, { data: documents }, { data: policies }, { data: staffWithLogin }, { data: reminders }] = await Promise.all([
    supabase.from('v_staff_compliance').select('staff_id, employee_code, full_name, compliance_status, expired_types, missing_types').order('full_name'),
    supabase.from('staff_document').select('id, staff_id, label, document_type, expires_on').not('expires_on', 'is', null).order('expires_on'),
    supabase.from('document_type_policy').select('document_type, label, is_mandatory').order('label'),
    supabase.from('staff').select('user_id, full_name').not('user_id', 'is', null).neq('employment_status', 'exited').order('full_name'),
    supabase.from('staff_document_reminder').select('document_id, threshold_days, generated_at').order('generated_at', { ascending: false }).limit(200),
  ]);

  const rows = compliance ?? [];
  const nonCompliant = rows.filter((r) => r.compliance_status === 'non_compliant');
  const incomplete = rows.filter((r) => r.compliance_status === 'incomplete');
  const nameByUser = new Map((staffWithLogin ?? []).map((s) => [s.user_id as string, s.full_name]));
  const lastReminder = new Map<string, number>();
  for (const r of reminders ?? []) if (!lastReminder.has(r.document_id)) lastReminder.set(r.document_id, r.threshold_days);
  const expiring = (documents ?? []).filter((d) => d.expires_on && daysUntil(d.expires_on, today) <= 60);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">Staff compliance</h1>
          <p className="text-sm text-muted-foreground">
            FR-D06 — police verification and medical certificates must stay valid. A nightly job (01:15 PKT) sends one reminder per document at 60, 30, 14 and 7 days and on the day of expiry.
          </p>
        </div>
        {canWrite && <RunCheckButton />}
      </div>

      <div className="grid gap-4 sm:grid-cols-3" data-testid="compliance-tiles">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">Non-compliant staff</CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-3xl font-semibold" data-testid="tile-non-compliant">
              {nonCompliant.length}
            </p>
            <p className="text-xs text-muted-foreground">A mandatory document has expired</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">Incomplete files</CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-3xl font-semibold" data-testid="tile-incomplete">
              {incomplete.length}
            </p>
            <p className="text-xs text-muted-foreground">A mandatory document is not on file</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">Expiring within 60 days</CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-3xl font-semibold">{expiring.filter((d) => daysUntil(d.expires_on!, today) >= 0).length}</p>
            <p className="text-xs text-muted-foreground">Documents with a reminder due</p>
          </CardContent>
        </Card>
      </div>

      {canWrite && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Record a document</CardTitle>
          </CardHeader>
          <CardContent>
            <AddDocumentForm
              staff={(staffWithLogin ?? []).map((s) => ({ userId: s.user_id as string, name: s.full_name }))}
              types={(policies ?? []).map((p) => ({ code: p.document_type, label: p.label }))}
            />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Documents expiring or expired</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="expiring-list">
          {expiring.length === 0 && <p className="text-muted-foreground">Nothing expires in the next 60 days.</p>}
          {expiring.map((d) => {
            const left = daysUntil(d.expires_on!, today);
            return (
              <div key={d.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="expiring-row">
                <div>
                  <p className="font-medium">
                    {nameByUser.get(d.staff_id) ?? 'Staff member'} · {d.label}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {left < 0 ? `Expired ${-left} day(s) ago` : left === 0 ? 'Expires today' : `Expires in ${left} day(s)`} ({d.expires_on})
                    {lastReminder.has(d.id) ? ` · ${lastReminder.get(d.id)}-day reminder sent` : ''}
                  </p>
                </div>
                {canWrite && <RenewForm documentId={d.id} />}
              </div>
            );
          })}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Compliance by staff member</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="compliance-list">
          {rows.length === 0 && <p className="text-muted-foreground">No staff records yet.</p>}
          {rows.map((r) => (
            <div key={r.staff_id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="compliance-row">
              <span>
                {r.full_name} <span className="text-xs text-muted-foreground">({r.employee_code})</span>
              </span>
              <span className="flex items-center gap-2">
                {(r.expired_types ?? []).length > 0 && <span className="text-xs text-destructive">expired: {(r.expired_types ?? []).map((t) => t.replace(/_/g, ' ')).join(', ')}</span>}
                {(r.missing_types ?? []).length > 0 && <span className="text-xs text-muted-foreground">missing: {(r.missing_types ?? []).map((t) => t.replace(/_/g, ' ')).join(', ')}</span>}
                <Badge variant={STATUS_VARIANT[r.compliance_status ?? 'incomplete'] ?? 'outline'}>{STATUS_LABEL[r.compliance_status ?? ''] ?? r.compliance_status}</Badge>
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
