import { supabaseServer } from '@/lib/supabase/server';
import { GRADING_SCHEME_ROLES } from '@/lib/validation';
import { GradingSchemeBoard } from './grading-board';
import type { GradingSchemeRow } from './grading-board';

/**
 * FR-J01. The Exam Controller's grade-scale screen.
 *
 * The role gate here is a courtesy, not the control: save_grading_scheme(),
 * activate_grading_scheme() and new_grading_scheme_version() run the same list
 * server-side, and both tables refuse a direct write from any client
 * connection. Showing an editor with every button disabled would be worse than
 * saying why.
 */
export default async function GradingSchemesPage() {
  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';
  const canEdit = GRADING_SCHEME_ROLES.includes(role as (typeof GRADING_SCHEME_ROLES)[number]);

  const { data: schemes } = await supabase
    .from('v_grading_scheme')
    .select('id, board, name, effective_from, version, status, band_count, bands, coverage_error')
    .order('board')
    .order('effective_from', { ascending: false });

  // A view's columns are all nullable to the type generator even when the
  // underlying ones are NOT NULL, so the narrowing is done once, here.
  const rows: GradingSchemeRow[] = (schemes ?? [])
    .filter((s) => s.id !== null && s.board !== null && s.effective_from !== null && s.status !== null)
    .map((s) => ({
      id: s.id!,
      board: s.board!,
      name: s.name ?? '',
      effective_from: s.effective_from!,
      version: s.version ?? 1,
      status: s.status!,
      band_count: s.band_count ?? 0,
      bands: s.bands,
      coverage_error: s.coverage_error,
    }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Grading schemes</h1>
        <p className="text-sm text-muted-foreground">
          FR-J01 — a grade scale is defined per board and must cover 0.00% to 100.00% with no gap and no overlap. Once a
          scheme is activated its bands are frozen for everyone: changing one would re-grade every result already
          computed against it, so a change is a new effective-dated version instead.
        </p>
      </div>

      {!canEdit && (
        <p className="text-sm text-muted-foreground" data-testid="grading-forbidden">
          Only an Exam Controller, Principal, Owner or Super Admin can configure a grade scale. These are the scales
          your school grades on.
        </p>
      )}

      <GradingSchemeBoard schemes={rows} canEdit={canEdit} />
    </div>
  );
}
