import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { StructureView, type StructureRow, type StructureLineRow, type StructureHistoryRow } from './structure-view';
import { pickActiveCampus, pickSessionForCampus } from '@/lib/campus-context';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function FeeStructurePage() {
  const supabase = await supabaseServer();

  // FR-A03 AC: the Fees module stays blocked until the onboarding
  // wizard's fee_heads step is actually done — skipped still blocks,
  // same as every other page reachable from the Fees module.
  const { data: feeHeadsStep } = await supabase
    .from('onboarding_progress')
    .select('status')
    .eq('step_key', 'fee_heads')
    .maybeSingle();
  if (feeHeadsStep && feeHeadsStep.status !== 'done') {
    return (
      <div className="space-y-4">
        <div>
          <h1 className="text-2xl font-semibold">Fee structure</h1>
          <p className="text-sm text-muted-foreground">Per-class fee lines for the current session, draft until published.</p>
        </div>
        <p className="text-sm text-muted-foreground">
          Set up your fee heads before building a fee structure.{' '}
          <Link href="/onboarding" className="text-primary underline">
            Finish the fee heads step
          </Link>{' '}
          in your setup checklist first.
        </p>
      </div>
    );
  }

  const [{ data: campuses }, { data: sessions }, { data: classLevels }, { data: feeHeads }] = await Promise.all([
    supabase.from('campus').select('id').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id, is_current, campus_id').eq('is_current', true).order('starts_on', { ascending: false }),
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('fee_head').select('id, code, name_en, is_mandatory').eq('is_active', true).order('code'),
  ]);

  const campus = (await pickActiveCampus(campuses));
  const session = pickSessionForCampus(sessions, campus?.id);

  let structure: StructureRow = null;
  let lines: StructureLineRow[] = [];
  let history: StructureHistoryRow[] = [];
  let missing: { head: string; classes: string[] }[] = [];

  if (campus && session) {
    const { data: structures } = await supabase
      .from('fee_structure')
      .select('id, status, version_no, effective_from, regulator_reference')
      .eq('campus_id', campus.id)
      .eq('session_id', session.id)
      .order('version_no', { ascending: false });

    structure = (structures ?? []).find((s) => s.status === 'draft') ?? (structures ?? []).find((s) => s.status === 'published') ?? null;
    history = (structures ?? []).filter((s) => s.id !== structure?.id);

    if (structure) {
      const { data: lineRows } = await supabase
        .from('fee_structure_line')
        .select('id, class_id, fee_head_id, group_code, amount_paisa, frequency, class_level(name_en), fee_head(code, name_en)')
        .eq('structure_id', structure.id);

      // Audit: publishing needs a line for every active class and mandatory fee head, but the page
      // never said which were missing. Work it out here and show it before Publish.
      const have = new Set((lineRows ?? []).map((l) => `${l.class_id}:${l.fee_head_id}`));
      missing = (feeHeads ?? [])
        .filter((h) => h.is_mandatory)
        .map((h) => ({
          head: h.name_en,
          classes: (classLevels ?? []).filter((c) => !have.has(`${c.id}:${h.id}`)).map((c) => c.name_en),
        }))
        .filter((m) => m.classes.length > 0);
      const order = new Map((classLevels ?? []).map((c, i) => [c.id, i]));
      lineRows?.sort((a, b) => (order.get(a.class_id) ?? 99) - (order.get(b.class_id) ?? 99));

      lines = (lineRows ?? []).map((l) => ({
        id: l.id,
        className: one(l.class_level)?.name_en ?? 'Unknown',
        groupCode: l.group_code,
        headName: one(l.fee_head)?.name_en ?? 'Unknown',
        amountPaisa: l.amount_paisa,
        frequency: l.frequency,
      }));
    }
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Fee structure</h1>
        <p className="text-sm text-muted-foreground">Per-class fee lines for the current session, draft until published.</p>
      </div>
      {campus && session ? (
        <StructureView
          campusId={campus.id}
          sessionId={session.id}
          structure={structure}
          lines={lines}
          history={history}
          classLevels={classLevels ?? []}
          feeHeads={feeHeads ?? []}
          missing={missing}
        />
      ) : (
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      )}
    </div>
  );
}
