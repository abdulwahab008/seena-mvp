import { supabaseServer } from '@/lib/supabase/server';
import { NewStudentForm } from './new-student-form';
import { StudentList } from './student-list';
import { getCurrentActor } from '@/lib/hr/current-role';

// Who create_student() lets admit; everyone else sees the roster only.
const ADMITTING_ROLES = ['super_admin', 'owner', 'principal', 'admissions_officer'];

export default async function StudentsPage() {
  const supabase = await supabaseServer();

  const actor = await getCurrentActor();
  const [{ data: campuses }, { data: students }] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    // FR-A15 AC1: an explicit filter, not just RLS — an Owner/Super Admin
    // also matches student_recycle_bin_read (the two SELECT policies are
    // OR'd), so an unfiltered query would silently readmit soft-deleted
    // students into this ordinary roster for those two roles.
    supabase.from('student').select('id, name_en, gr_number, status').is('deleted_at', null).order('created_at', { ascending: false }),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Students</h1>
        <p className="text-sm text-muted-foreground">Student profiles, each with a permanent GR number from admission.</p>
      </div>
      {actor && ADMITTING_ROLES.includes(actor.role) && <NewStudentForm campuses={campuses ?? []} />}
      <StudentList students={students ?? []} />
    </div>
  );
}
