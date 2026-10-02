import { supabaseServer } from '@/lib/supabase/server';
import { ConsentManager, type AttentionRow, type StudentOption } from './consent-manager';

// record_consent() and build_marketing_gallery_export() each enforce their
// own (different) role sets — this gate is the union, deliberately
// cosmetic. A receptionist who reaches the page can capture a counter
// consent and will simply be refused the gallery build by the RPC.
const CONSENT_ROLES = ['super_admin', 'owner', 'principal', 'admissions_officer', 'receptionist'];

export default async function ConsentPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';
  const canView = CONSENT_ROLES.includes(role);

  let campuses: Array<{ id: string; code: string; name: string }> = [];
  let students: StudentOption[] = [];
  let attention: AttentionRow[] = [];
  let purposes: Array<{ code: string; description_en: string; requires_explicit_grant: boolean }> = [];

  if (canView) {
    const [{ data: campusRows }, { data: studentRows }, { data: attentionRows }, { data: purposeRows }] = await Promise.all([
      supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
      supabase.from('student').select('id, name_en, gr_number').eq('status', 'active').order('name_en').limit(500),
      supabase
        .from('v_consent_attention')
        .select('student_id, student_name, gr_number, purpose_code, has_conflict, reconsent_required, granted_count, denied_count, last_recorded_at')
        .or('has_conflict.eq.true,reconsent_required.eq.true'),
      supabase.from('consent_purpose').select('code, description_en, requires_explicit_grant').order('code'),
    ]);
    campuses = campusRows ?? [];
    students = (studentRows ?? []) as StudentOption[];
    attention = (attentionRows ?? []) as AttentionRow[];
    purposes = purposeRows ?? [];
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Consent</h1>
        <p className="text-sm text-muted-foreground">
          FR-T15 — what each family has agreed to for photographs, data sharing and messaging, and where those choices are
          enforced: the marketing gallery excludes anyone without a live grant, and a withdrawn messaging consent suppresses that
          guardian on the next broadcast.
        </p>
      </div>
      {canView ? (
        <ConsentManager campuses={campuses} students={students} attention={attention} purposes={purposes} role={role} />
      ) : (
        <p className="text-sm text-muted-foreground" data-testid="consent-forbidden">
          You do not have permission to view consent records.
        </p>
      )}
    </div>
  );
}
