import { supabaseServer } from '@/lib/supabase/server';
import { AuditExportView, type AuditExportJobRow } from './audit-export-view';

export default async function AuditExportPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role;
  // FR-T14: Owner/Super Admin-only UI surface — request_audit_export's own
  // RPC also permits Principal (AC3 needs a Principal's own request to
  // succeed, just come back scoped by RLS), but this UI is deliberately
  // narrower, mirroring the Recycle Bin (FR-A15) and Branding (FR-A18)
  // admin surfaces' own Owner/Super-Admin gating.
  const canView = role === 'super_admin' || role === 'owner';

  let campuses: Array<{ id: string; code: string; name: string }> = [];
  let jobs: AuditExportJobRow[] = [];
  if (canView) {
    const { data: campusRows } = await supabase.from('campus').select('id, code, name').eq('status', 'active').order('code');
    campuses = campusRows ?? [];

    const { data: jobRows } = await supabase
      .from('audit_export_job')
      .select('id, from_date, to_date, table_names, campus_id, status, row_count, download_url, download_expires_at, requested_at, error')
      .order('requested_at', { ascending: false })
      .limit(20);
    jobs = jobRows ?? [];
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Audit trail export</h1>
        <p className="text-sm text-muted-foreground">
          FR-T14 — export every write event for a date range and set of entities as evidence for an auditor or a court, with a
          signed download link valid for 24 hours.
        </p>
      </div>
      {canView ? (
        <AuditExportView campuses={campuses} jobs={jobs} />
      ) : (
        <p className="text-sm text-muted-foreground">Only an Owner or Super Admin can export the audit trail.</p>
      )}
    </div>
  );
}
