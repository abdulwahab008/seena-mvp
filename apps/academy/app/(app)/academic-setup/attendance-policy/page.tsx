import { supabaseServer } from '@/lib/supabase/server';
import { PolicyForm } from './policy-form';

export default async function AttendancePolicyPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  const { data: sessions } = campusId
    ? await supabase.from('academic_session').select('id').eq('is_current', true).limit(1)
    : { data: [] as never[] };
  const sessionId = sessions?.[0]?.id;

  const { data: policy } = campusId && sessionId ? await supabase.rpc('resolve_attendance_policy', { p_campus_id: campusId, p_session_id: sessionId }) : { data: null };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Attendance Policy</h1>
        <p className="text-sm text-muted-foreground">
          FR-G01 — configure once per session; every edit is effective-dated, never a retroactive rewrite.
        </p>
      </div>
      {!campusId || !sessionId ? (
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      ) : (
        <PolicyForm
          campusId={campusId}
          sessionId={sessionId}
          current={
            policy
              ? {
                  startTime: (policy as Record<string, unknown>).start_time as string,
                  lateThresholdMinutes: (policy as Record<string, unknown>).late_threshold_minutes as number,
                  lockWindowHours: (policy as Record<string, unknown>).lock_window_hours as number,
                  mode: (policy as Record<string, unknown>).mode as string,
                  saturdayWorking: (policy as Record<string, unknown>).saturday_working as boolean,
                }
              : null
          }
        />
      )}
    </div>
  );
}
