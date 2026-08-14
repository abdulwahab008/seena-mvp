import { supabaseServer } from '@/lib/supabase/server';
import { BoardExportView, type PastRun } from './board-export-view';

/**
 * FR-T11. Registration is the Exam Controller's job, and a Principal or
 * Owner signs it off — the same set begin_board_export_run() admits. An
 * Admissions Officer is named on the requirement as an actor but only ever
 * reads a run, so the write surface stays with the three who own the
 * deadline.
 */
const EXPORT_ROLES = ['super_admin', 'owner', 'principal', 'exam_controller'];

// Boards this software ships a registration profile for. Read from the
// profiles rather than the enum: CAMBRIDGE is a board, but not one that
// takes a registration file in this format.
export default async function BoardExportPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';

  if (!EXPORT_ROLES.includes(role)) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Board registration export</h1>
        <p className="text-sm text-muted-foreground" data-testid="board-export-forbidden">
          Only an Owner, Super Admin, Principal or Exam Controller can produce a board registration file.
        </p>
      </div>
    );
  }

  const [{ data: campusRows }, { data: sessionRows }, { data: classRows }, { data: profileRows }, { data: runRows }] =
    await Promise.all([
      supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
      supabase.from('academic_session').select('id, name').order('starts_on', { ascending: false }),
      supabase.from('class_level').select('id, code, name_en').eq('is_active', true).order('ordinal'),
      supabase.from('board_profile').select('board_code').eq('export_kind', 'registration'),
      supabase
        .from('board_export_run')
        .select('id, board_code, class_level_id, status, row_count, checksum, file_path, generated_at, requested_at')
        .order('requested_at', { ascending: false })
        .limit(20),
    ]);

  const runs = (runRows ?? []) as PastRun[];

  // The register's own names, so a blocking error reads "Ayesha Noor" and
  // not a uuid — the controller has to go and find the child's file.
  const studentIds = [
    ...new Set(
      ((
        await supabase
          .from('board_export_row_error')
          .select('student_id')
          .in('run_id', runs.length > 0 ? runs.map((r) => r.id) : ['00000000-0000-0000-0000-000000000000'])
      ).data ?? []).map((e) => e.student_id as string),
    ),
  ];
  const { data: studentRows } =
    studentIds.length > 0
      ? await supabase.from('student').select('id, name_en, gr_number').in('id', studentIds)
      : { data: [] };
  const studentNames = Object.fromEntries(
    (studentRows ?? []).map((s) => [s.id as string, `${s.name_en} (${s.gr_number})`]),
  );

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Board registration export</h1>
        <p className="text-sm text-muted-foreground">
          FR-T11 — the registration file your board demands, in its exact column order, checked candidate by candidate
          before it is produced. A board bounces the whole file for one bad row, so nothing is generated while anything is
          blocking. Check the data early and often; the deadline does not move.
        </p>
      </div>

      <BoardExportView
        campuses={campusRows ?? []}
        sessions={sessionRows ?? []}
        classLevels={classRows ?? []}
        boards={[...new Set((profileRows ?? []).map((p) => p.board_code as string))].sort()}
        runs={runs}
        studentNames={studentNames}
      />
    </div>
  );
}
