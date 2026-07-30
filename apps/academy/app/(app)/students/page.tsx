import { supabaseServer } from '@/lib/supabase/server';
import { NewStudentForm } from './new-student-form';
import { StudentList } from './student-list';

export default async function StudentsPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: students }] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    supabase.from('student').select('id, name_en, gr_number, status').order('created_at', { ascending: false }),
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
