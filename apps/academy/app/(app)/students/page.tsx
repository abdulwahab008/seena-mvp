import { supabaseServer } from '@/lib/supabase/server';
import { NewStudentForm } from './new-student-form';
import { StudentList } from './student-list';

export default async function StudentsPage() {
  const supabase = await supabaseServer();

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
        <p className="text-sm text-muted-foreground">FR-C04 — student profiles, permanently GR-numbered on admission (FR-C01).</p>
      </div>
      <NewStudentForm campuses={campuses ?? []} />
      <StudentList students={students ?? []} />
    </div>
  );
}
