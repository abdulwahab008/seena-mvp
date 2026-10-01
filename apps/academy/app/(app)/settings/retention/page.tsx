import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { DryRunButton, PolicyRow } from './policy-forms';

const LABEL: Record<string, { name: string; what: string }> = {
  student_identity: { name: 'Student identifiers', what: 'B-Form number and photo are removed after the student leaves.' },
  student_name_gr: { name: 'Student name and GR number', what: 'Replaced by a one-way pseudonym. Never for a student named on an issued certificate.' },
  guardian_contact: { name: 'Guardian contact details', what: 'CNIC, phones and email are removed once every linked child has left.' },
  fee_ledger: { name: 'Fee ledger', what: 'Deleted after the end of the calendar year plus the retention period.' },
};
const ORDER = ['student_identity', 'student_name_gr', 'guardian_contact', 'fee_ledger'] as const;

export default async function RetentionPage() {
  const supabase = await supabaseServer();
  const [{ data: policies }, { data: runs }] = await Promise.all([
    supabase.from('retention_policy').select('tenant_id, data_category, retention_years'),
    supabase.from('retention_purge_run').select('id, as_of, dry_run, status, candidates_count, purged_count, exempted_count, started_at').order('started_at', { ascending: false }).limit(15),
  ]);
  const { data: me } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from('app_user').select('app_role').eq('user_id', me.user?.id ?? '').maybeSingle();
  const canEdit = profile?.app_role === 'super_admin';
  const years = (cat: string) => (policies ?? []).find((p) => p.data_category === cat && p.tenant_id !== null)?.retention_years ?? (policies ?? []).find((p) => p.data_category === cat)?.retention_years ?? 0;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Data retention</h1>
        <p className="text-sm text-muted-foreground">
          FR-T16 — personal data of long-departed students is purged on a schedule; statutory records stay. A nightly job runs at 03:30, as a dry run on the 1st of each month. Anyone named on an issued certificate keeps their name and GR number.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Retention periods</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="retention-policies">
          {ORDER.map((c) => (
            <div key={c} className="flex flex-wrap items-center justify-between gap-2 border-b pb-3" data-testid="policy-row">
              <span>
                <strong>{LABEL[c]!.name}</strong>
                <span className="block text-xs text-muted-foreground">{LABEL[c]!.what}</span>
              </span>
              <PolicyRow category={c} years={years(c)} canEdit={canEdit} />
            </div>
          ))}
          {!canEdit && <p className="text-xs text-muted-foreground">Only a Super Admin can change these.</p>}
        </CardContent>
      </Card>

      {canEdit && <DryRunButton />}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Runs</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="retention-runs">
          {(runs ?? []).length === 0 && <p className="text-muted-foreground">No runs yet.</p>}
          {(runs ?? []).map((r) => (
            <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="retention-run">
              <span>
                {r.as_of} · {r.candidates_count} candidates · {r.purged_count} purged · {r.exempted_count} exempt
              </span>
              <span className="flex gap-2">
                {r.dry_run && <Badge variant="outline">dry run</Badge>}
                <Badge variant={r.status === 'done' ? 'success' : 'outline'}>{r.status}</Badge>
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
