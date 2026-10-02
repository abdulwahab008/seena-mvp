import { supabaseServer } from '@/lib/supabase/server';
import { BookingForm } from './booking-form';
import { InterviewList, type InterviewRow } from './interview-list';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function InterviewsPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  const [{ data: appRows }, { data: panelRows }, { data: interviewRows }] = await Promise.all([
    campusId
      ? supabase
          .from('admission_application')
          .select('id, application_no, admission_enquiry(child_name)')
          .eq('campus_id', campusId)
          .in('status', ['submitted', 'under_review'])
      : Promise.resolve({ data: [] as never[] }),
    supabase.from('app_user').select('user_id, full_name, app_role').order('full_name'),
    supabase
      .from('admission_interview')
      .select('id, application_id, starts_at, ends_at, venue, status, panel_user_id, admission_application(application_no, admission_enquiry(child_name))')
      .order('starts_at', { ascending: false }),
  ]);

  const panelNameByUserId = new Map((panelRows ?? []).map((p) => [p.user_id, p.full_name]));

  const applications = (appRows ?? []).map((a) => ({
    id: a.id,
    applicationNo: a.application_no,
    childName: one(a.admission_enquiry)?.child_name ?? 'Unknown',
  }));

  const panelMembers = (panelRows ?? []).map((p) => ({ userId: p.user_id, fullName: p.full_name, appRole: p.app_role }));

  const interviews: InterviewRow[] = (interviewRows ?? []).map((i) => {
    const app = one(i.admission_application);
    return {
      id: i.id,
      applicationId: i.application_id,
      applicationNo: app?.application_no ?? null,
      childName: one(app?.admission_enquiry ?? null)?.child_name ?? 'Unknown',
      panelName: panelNameByUserId.get(i.panel_user_id) ?? 'Unknown',
      startsAt: i.starts_at,
      endsAt: i.ends_at,
      venue: i.venue,
      status: i.status,
    };
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Admission interviews</h1>
        <p className="text-sm text-muted-foreground">
          FR-B13 — book conflict-free interview slots against a panel member's calendar.
        </p>
      </div>
      {!campusId ? (
        <p className="text-sm text-muted-foreground">No active campus found.</p>
      ) : (
        <>
          <BookingForm applications={applications} panelMembers={panelMembers} />
          <InterviewList interviews={interviews} />
        </>
      )}
    </div>
  );
}
