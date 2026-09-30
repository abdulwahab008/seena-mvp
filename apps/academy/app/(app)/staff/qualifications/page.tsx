import { supabaseServer } from '@/lib/supabase/server';
import { QualificationRegistry } from './qualification-registry';

export const dynamic = 'force-dynamic';

export default async function StaffQualificationsPage() {
  const supabase = await supabaseServer();

  const [
    { data: staff },
    { data: qualifications },
    { data: { user } },
  ] = await Promise.all([
    supabase.from('app_user').select('user_id, full_name').order('full_name'),
    supabase
      .from('staff_qualification')
      .select('id, staff_id, level, discipline, institution, year_completed, verification_status, document_id, staff_document:document_id(id, label, storage_path)')
      .order('created_at', { ascending: false }),
    supabase.auth.getUser(),
  ]);

  const { data: currentUser } = user
    ? await supabase.from('app_user').select('user_id, app_role, full_name').eq('user_id', user.id).maybeSingle()
    : { data: null };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff qualifications</h1>
        <p className="text-sm text-muted-foreground">
          Degrees, certifications, and transcripts on file per staff member with official HR verification for board affiliation inspections.
        </p>
      </div>
      <QualificationRegistry
        staff={staff ?? []}
        qualifications={(qualifications ?? []) as any}
        currentUser={currentUser ? { userId: currentUser.user_id, role: currentUser.app_role, name: currentUser.full_name } : undefined}
      />
    </div>
  );
}
