import { supabaseServer } from '@/lib/supabase/server';
import { QualificationRegistry } from './qualification-registry';

export default async function StaffQualificationsPage() {
  const supabase = await supabaseServer();

  const [{ data: staff }, { data: qualifications }] = await Promise.all([
    supabase.from('app_user').select('user_id, full_name').order('full_name'),
    supabase
      .from('staff_qualification')
      .select('id, staff_id, level, discipline, institution, year_completed, verification_status')
      .order('created_at', { ascending: false }),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff qualifications</h1>
        <p className="text-sm text-muted-foreground">
          FR-D02 — degrees and certifications on file per staff member, with an HR verification status for board affiliation inspections.
        </p>
      </div>
      <QualificationRegistry staff={staff ?? []} qualifications={qualifications ?? []} />
    </div>
  );
}
