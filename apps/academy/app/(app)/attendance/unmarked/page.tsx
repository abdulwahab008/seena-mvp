import { supabaseServer } from '@/lib/supabase/server';
import { UnmarkedView } from './unmarked-view';

export default async function UnmarkedAttendancePage() {
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Unmarked Attendance</h1>
        <p className="text-sm text-muted-foreground">
          FR-G13 — sections with no or partial attendance for a date, so gaps are caught the same day, not at report card time.
        </p>
      </div>
      {!campusId ? <p className="text-sm text-muted-foreground">No active campus found.</p> : <UnmarkedView campusId={campusId} />}
    </div>
  );
}
