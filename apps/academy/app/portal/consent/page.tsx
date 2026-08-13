import { supabaseServer } from '@/lib/supabase/server';
import { PortalConsentForm, type PortalPurpose } from './portal-consent-form';

export default async function PortalConsentPage({ searchParams }: { searchParams: Promise<{ child?: string }> }) {
  const { child: childParam } = await searchParams;
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // student_parent_read_own_children (FR-C11) already scopes this to the
  // signed-in guardian's own children.
  const { data: studentRows } = await supabase.from('student').select('id, name_en').eq('status', 'active').order('name_en');
  const children = studentRows ?? [];
  const selectedId = childParam ?? children[0]?.id;

  // Which guardian row is this login? record_consent() re-checks it, but the
  // form needs the id to submit and the parent has exactly one.
  const { data: guardianRow } = await supabase.from('guardian').select('id, name_en').eq('auth_user_id', user!.id).maybeSingle();

  const [{ data: purposeRows }, { data: textRows }, { data: stateRows }, { data: decisionRows }] = await Promise.all([
    supabase.from('consent_purpose').select('code, description_en, description_ur').order('code'),
    supabase.from('consent_text_version').select('purpose_code, version, body_en, effective_from').order('version', { ascending: false }),
    selectedId
      ? supabase.rpc('consent_state_for_student', { p_student_id: selectedId })
      : Promise.resolve({ data: [] as never[] }),
    selectedId
      ? supabase
          .from('v_consent_guardian_decision')
          .select('purpose_code, granted_by_guardian_id, decision, recorded_at')
          .eq('student_id', selectedId)
      : Promise.resolve({ data: [] as never[] }),
  ]);

  const today = new Date().toISOString().slice(0, 10);
  const currentText = new Map<string, string>();
  for (const t of textRows ?? []) {
    if (t.effective_from <= today && !currentText.has(t.purpose_code)) currentText.set(t.purpose_code, t.body_en);
  }

  // Every column of a view is nullable as far as the generated types are
  // concerned; the view's own predicates guarantee they are not.
  const myDecisions = new Map<string, { decision: string; recorded_at: string }>();
  for (const d of decisionRows ?? []) {
    if (guardianRow && d.granted_by_guardian_id === guardianRow.id && d.purpose_code && d.decision && d.recorded_at) {
      myDecisions.set(d.purpose_code, { decision: d.decision, recorded_at: d.recorded_at });
    }
  }

  const stateByPurpose = new Map((stateRows ?? []).map((s) => [s.purpose_code, s]));

  const purposes: PortalPurpose[] = (purposeRows ?? []).map((p) => ({
    code: p.code,
    descriptionEn: p.description_en,
    descriptionUr: p.description_ur,
    bodyEn: currentText.get(p.code) ?? p.description_en,
    myDecision: myDecisions.get(p.code)?.decision ?? null,
    myDecisionAt: myDecisions.get(p.code)?.recorded_at ?? null,
    effective: stateByPurpose.get(p.code)?.effective ?? false,
    hasConflict: stateByPurpose.get(p.code)?.has_conflict ?? false,
  }));

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Consent</h2>
        <p className="text-sm text-muted-foreground">
          FR-T15 — what you have agreed to for your child. Changing an answer here takes effect immediately: a withdrawn
          photograph consent removes your child from the next marketing gallery, and a withdrawn messaging consent stops the next
          broadcast to your number.
        </p>
      </div>

      {children.length === 0 || !guardianRow ? (
        <p className="text-sm text-muted-foreground" data-testid="portal-consent-empty">
          No enrolled child found on this account.
        </p>
      ) : (
        <PortalConsentForm
          childOptions={children.map((c) => ({ id: c.id, name: c.name_en }))}
          selectedId={selectedId!}
          guardianId={guardianRow.id}
          purposes={purposes}
        />
      )}
    </div>
  );
}
