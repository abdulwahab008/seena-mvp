import { supabaseServer } from '@/lib/supabase/server';
import { RecycleBinList, type RecycleBinRow } from './recycle-bin-list';

export default async function RecycleBinPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role;
  // FR-A15 AC2: "When an Owner opens the Recycle Bin" — Owner/Super Admin
  // only, mirroring restore_record()'s own FORBIDDEN check and the
  // student_recycle_bin_read RLS policy that actually gates the query below.
  const canView = role === 'super_admin' || role === 'owner';

  let rows: RecycleBinRow[] = [];
  if (canView) {
    const { data: deletedStudents } = await supabase
      .from('student')
      .select('id, name_en, gr_number, deleted_at, deleted_by')
      .not('deleted_at', 'is', null)
      .order('deleted_at', { ascending: false });

    const deletedByIds = Array.from(
      new Set((deletedStudents ?? []).map((s) => s.deleted_by).filter((v): v is string => v !== null))
    );
    const { data: deleters } =
      deletedByIds.length > 0
        ? await supabase.from('app_user').select('user_id, full_name').in('user_id', deletedByIds)
        : { data: [] };
    const deleterNameById = new Map((deleters ?? []).map((d) => [d.user_id, d.full_name]));

    rows = (deletedStudents ?? []).map((s) => ({
      id: s.id,
      nameEn: s.name_en,
      grNumber: s.gr_number,
      deletedAt: s.deleted_at as string,
      deletedByName: s.deleted_by ? (deleterNameById.get(s.deleted_by) ?? 'Unknown') : 'Unknown',
    }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Recycle Bin</h1>
        <p className="text-sm text-muted-foreground">
          FR-A15 — soft-deleted students. Restore brings a student, its enrolment, and its challans back exactly as they were.
        </p>
      </div>
      {canView ? (
        <RecycleBinList students={rows} />
      ) : (
        <p className="text-sm text-muted-foreground">Only an Owner or Super Admin can view the Recycle Bin.</p>
      )}
    </div>
  );
}
