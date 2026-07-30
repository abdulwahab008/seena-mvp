import { supabaseServer } from '@/lib/supabase/server';
import { StructureView, type StructureRow, type StructureLineRow } from './structure-view';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function FeeStructurePage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: sessions }, { data: classLevels }, { data: feeHeads }] = await Promise.all([
    supabase.from('campus').select('id').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id').eq('is_current', true).order('starts_on', { ascending: false }),
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('fee_head').select('id, code, name_en').eq('is_active', true).order('code'),
  ]);

  const campus = campuses?.[0];
  const session = sessions?.[0];

  let structure: StructureRow = null;
  let lines: StructureLineRow[] = [];

  if (campus && session) {
    const { data: structures } = await supabase
      .from('fee_structure')
      .select('id, status, version_no')
      .eq('campus_id', campus.id)
      .eq('session_id', session.id)
      .order('created_at', { ascending: false });

    structure = (structures ?? []).find((s) => s.status === 'draft') ?? (structures ?? []).find((s) => s.status === 'published') ?? null;

    if (structure) {
      const { data: lineRows } = await supabase
        .from('fee_structure_line')
        .select('id, group_code, amount_paisa, frequency, class_level(name_en), fee_head(code, name_en)')
        .eq('structure_id', structure.id);

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
        <p className="text-sm text-muted-foreground">FR-K02 — per-class fee lines for the current session, draft until published.</p>
      </div>
      {campus && session ? (
        <StructureView
          campusId={campus.id}
          sessionId={session.id}
          structure={structure}
          lines={lines}
          classLevels={classLevels ?? []}
          feeHeads={feeHeads ?? []}
        />
      ) : (
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      )}
    </div>
  );
}
