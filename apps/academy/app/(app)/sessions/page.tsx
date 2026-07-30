import { supabaseServer } from '@/lib/supabase/server';
import { SessionList, type SessionRow } from './session-list';
import { CreateSessionForm } from './create-session-form';

export default async function SessionsPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const { data: sessions } = await supabase
    .from('academic_session')
    .select('id, name, starts_on, ends_on, status, is_current, campus:campus_id(name), academic_term(name, starts_on, ends_on, weightage)')
    .order('starts_on');

  const rows: SessionRow[] = (sessions ?? []).map((s) => ({
    id: s.id,
    name: s.name,
    starts_on: s.starts_on,
    ends_on: s.ends_on,
    status: s.status,
    is_current: s.is_current,
    campus_name: (s.campus as { name: string } | null)?.name ?? '—',
    terms: s.academic_term ?? [],
  }));

  const firstCampus = campuses?.[0];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Academic Sessions</h1>
        <p className="text-sm text-muted-foreground">FR-A04/FR-A05 — one current session per campus, and its terms.</p>
      </div>
      {firstCampus && <CreateSessionForm campusId={firstCampus.id} />}
      <SessionList sessions={rows} />
    </div>
  );
}
