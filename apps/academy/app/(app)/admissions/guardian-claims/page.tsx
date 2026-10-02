import { supabaseServer } from '@/lib/supabase/server';
import { ClaimsDesk, type ClaimRow, type AttemptRow } from './claims-desk';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function GuardianClaimsPage() {
  const supabase = await supabaseServer();
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

  const [claimsRes, attemptsRes] = await Promise.all([
    supabase
      .from('guardian_claim')
      .select('id, status, review_reason, review_note, created_at, student:student_id(name_en, gr_number), guardian:guardian_id(name_en, phone_e164)')
      .order('created_at', { ascending: false })
      .limit(100),
    supabase
      .from('guardian_claim_attempt')
      .select('id, gr_digits, outcome, created_at')
      .neq('outcome', 'matched')
      .gte('created_at', since)
      .order('created_at', { ascending: false })
      .limit(50),
  ]);

  const claims: ClaimRow[] = (claimsRes.data ?? []).map((c) => ({
    id: c.id,
    status: c.status,
    reason: c.review_reason,
    note: c.review_note,
    createdAt: c.created_at,
    studentName: one(c.student)?.name_en ?? 'Unknown',
    grNumber: one(c.student)?.gr_number ?? null,
    guardianName: one(c.guardian)?.name_en ?? 'Unknown',
    hasPhone: Boolean(one(c.guardian)?.phone_e164),
  }));
  const attempts: AttemptRow[] = (attemptsRes.data ?? []).map((a) => ({
    id: a.id,
    gr: a.gr_digits,
    outcome: a.outcome,
    at: a.created_at,
  }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Parent portal claims</h1>
        <p className="text-sm text-muted-foreground">
          FR-N01 — parents who could not receive the activation code on the number we hold land here. Fix the phone on the
          guardian record, then approve; nobody can self-enter a different number.
        </p>
      </div>
      <ClaimsDesk claims={claims} attempts={attempts} />
    </div>
  );
}
