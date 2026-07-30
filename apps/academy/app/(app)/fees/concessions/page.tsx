import { supabaseServer } from '@/lib/supabase/server';
import { CreateSchemeForm } from './create-scheme-form';
import { SchemeList, type SchemeRow } from './scheme-list';
import { FeePolicyForm } from './fee-policy-form';

export default async function ConcessionsPage() {
  const supabase = await supabaseServer();

  const [{ data: feeHeads }, { data: schemes }, { data: policy }] = await Promise.all([
    supabase.from('fee_head').select('id, code, name_en').eq('is_active', true).order('code'),
    supabase
      .from('concession_scheme')
      .select('id, code, name_en, name_ur, calc_type, value, applicable_head_ids, requires_document, is_active')
      .order('code'),
    supabase.from('fee_policy').select('max_stacked_concession_pct').maybeSingle(),
  ]);

  const headNameById = new Map((feeHeads ?? []).map((h) => [h.id, h.name_en]));
  const rows: SchemeRow[] = (schemes ?? []).map((s) => ({
    id: s.id,
    code: s.code,
    name_en: s.name_en,
    name_ur: s.name_ur,
    calc_type: s.calc_type,
    value: s.value,
    requires_document: s.requires_document,
    is_active: s.is_active,
    headNames: s.applicable_head_ids.map((id: string) => headNameById.get(id) ?? 'Unknown'),
  }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Concession schemes</h1>
        <p className="text-sm text-muted-foreground">
          FR-K05 — the catalogue FR-K06&apos;s award workflow will apply against. Applicability is per fee head, never global.
        </p>
      </div>
      <div className="space-y-2">
        <h2 className="text-lg font-medium">Fee policy</h2>
        <p className="text-sm text-muted-foreground">
          FR-K08 — the ceiling combined concessions on one fee line can never exceed, applied by the monthly challan job itself.
        </p>
        <FeePolicyForm maxStackedConcessionPct={policy?.max_stacked_concession_pct ?? null} />
      </div>
      <CreateSchemeForm feeHeads={feeHeads ?? []} />
      <SchemeList schemes={rows} />
    </div>
  );
}
