import { supabaseServer } from '@/lib/supabase/server';
import type { TimetableExportLayout } from '@/lib/validation';
import { TimetableExportView, type ExportJobRow, type StaffOption, type VersionOption } from './timetable-export-view';

const ADMIN_ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller'];
const TEACHING_ROLES = ['class_teacher', 'subject_teacher', 'head_of_department'];

export default async function TimetableExportPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';

  const isAdmin = ADMIN_ROLES.includes(role);
  const isTeacher = TEACHING_ROLES.includes(role);

  // The UI mirrors request_timetable_export()'s own rule; the RPC is what
  // actually enforces it — a hand-crafted form post gets EXPORT_SCOPE_
  // FORBIDDEN, not somebody else's sheet.
  const layouts: TimetableExportLayout[] = isAdmin
    ? ['section', 'teacher', 'master']
    : role === 'class_teacher'
      ? ['section', 'teacher']
      : isTeacher
        ? ['teacher']
        : [];

  let versions: VersionOption[] = [];
  let staff: StaffOption[] = [];
  let jobs: ExportJobRow[] = [];

  if (layouts.length > 0) {
    const { data: sessions } = await supabase.from('academic_session').select('id').eq('is_current', true).limit(1);
    const sessionId = sessions?.[0]?.id;

    const { data: versionRows } = sessionId
      ? await supabase
          .from('timetable_version')
          .select('id, name, version_no, status, shift, campus_id, campus:campus_id(code, name)')
          .eq('session_id', sessionId)
          .order('version_no', { ascending: false })
      : { data: [] as never[] };
    versions = (versionRows ?? []) as unknown as VersionOption[];

    if (isAdmin) {
      const { data: staffRows } = await supabase
        .from('app_user')
        .select('user_id, full_name')
        .in('app_role', ['subject_teacher', 'class_teacher', 'head_of_department'])
        .order('full_name');
      staff = staffRows ?? [];
    }

    const { data: jobRows } = await supabase
      .from('timetable_export_job')
      .select('id, layout, status, page_count, missing_glyph_count, font_family, download_url, download_expires_at, requested_at, error')
      .order('requested_at', { ascending: false })
      .limit(20);
    jobs = (jobRows ?? []) as ExportJobRow[];
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Timetable print &amp; export</h1>
        <p className="text-sm text-muted-foreground">
          FR-F15 — per-section and per-teacher sheets on A4 portrait, the master grid on A3 landscape, as a single PDF with a
          signed download link valid for 24 hours.
        </p>
      </div>
      {layouts.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="timetable-export-forbidden">
          Your role cannot export timetables.
        </p>
      ) : (
        <TimetableExportView layouts={layouts} versions={versions} staff={staff} jobs={jobs} canChooseStaff={isAdmin} />
      )}
    </div>
  );
}
