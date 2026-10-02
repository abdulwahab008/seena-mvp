import { supabaseServer } from '@/lib/supabase/server';
import { formatPkrCompact } from '@/lib/format-money';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';

const waLink = (phone: string) => `https://wa.me/${phone.replace(/\D/g, '')}`;

export default async function PrincipalTodayPage() {
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('v_principal_today').select('*').order('campus_id');

  if (!campuses || campuses.length === 0) {
    return <EmptyState title="No campus to show" description="This screen is for principals and owners with a campus assigned." />;
  }

  const panels = await Promise.all(
    campuses.map(async (c) => {
      const campusId = c.campus_id as string;
      const [{ data: unmarked }, { data: absentees }, { data: campus }] = await Promise.all([
        supabase.rpc('fn_unmarked_sections', { p_campus_id: campusId }),
        supabase.rpc('fn_today_absentees', { p_campus_id: campusId }),
        supabase.from('campus').select('name').eq('id', campusId).maybeSingle(),
      ]);
      return { c, name: campus?.name ?? 'Campus', unmarked: unmarked ?? [], absentees: absentees ?? [] };
    }),
  );

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-semibold">Today</h1>
        <p className="text-sm text-muted-foreground">FR-S03 — live, not the nightly rollup: what needs attention right now.</p>
      </div>

      {panels.map(({ c, name, unmarked, absentees }) => (
        <section key={c.campus_id} className="space-y-4" data-testid="today-campus">
          <h2 className="text-lg font-medium">
            {name} · {c.on_date}
          </h2>
          <div className="grid gap-4 sm:grid-cols-3">
            <Card>
              <CardHeader className="p-4 pb-2">
                <CardDescription>Attendance</CardDescription>
                <CardTitle className="text-2xl" data-testid="sections-marked">
                  {c.sections_marked}/{c.sections_total} sections marked
                </CardTitle>
              </CardHeader>
            </Card>
            <Card>
              <CardHeader className="p-4 pb-2">
                <CardDescription>Absent today</CardDescription>
                <CardTitle className="text-2xl" data-testid="absent-count">
                  {c.absent_count}
                </CardTitle>
              </CardHeader>
            </Card>
            <Card>
              <CardHeader className="p-4 pb-2">
                <CardDescription>Collected today (confirmed receipts)</CardDescription>
                <CardTitle className="text-2xl" data-testid="collected-today">
                  {formatPkrCompact(Number(c.collected_today_paisa ?? 0))}
                </CardTitle>
                {Number(c.pending_online_count ?? 0) > 0 && (
                  <p className="text-xs text-muted-foreground" data-testid="pending-online">
                    {c.pending_online_count} online payment(s) awaiting confirmation — not included
                  </p>
                )}
              </CardHeader>
            </Card>
          </div>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Sections that have not marked attendance ({unmarked.length})</CardTitle>
            </CardHeader>
            <CardContent className="space-y-1 text-sm">
              {unmarked.length === 0 && <p className="text-muted-foreground">Every section has marked attendance.</p>}
              {unmarked.map((u) => (
                <div key={u.section_id} className="flex justify-between border-b py-1" data-testid="unmarked-section">
                  <span>
                    {u.class_name} · {u.section_name}
                  </span>
                  <span className="text-muted-foreground">{u.class_teacher_name ?? 'no class teacher assigned'}</span>
                </div>
              ))}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Absent students ({absentees.length})</CardTitle>
            </CardHeader>
            <CardContent className="space-y-1 text-sm">
              {absentees.length === 0 && <p className="text-muted-foreground">No absences recorded yet.</p>}
              {absentees.map((a) => (
                <div key={a.enrolment_id} className="flex items-center justify-between gap-2 border-b py-1" data-testid="absentee-row">
                  <span>
                    {a.student_name} · GR {a.gr_number} · {a.class_name} {a.section_name}
                  </span>
                  {a.guardian_phone ? (
                    <a className="underline-offset-2 hover:underline" href={waLink(a.guardian_phone)} target="_blank" rel="noreferrer" data-testid="whatsapp-link">
                      {a.guardian_name} · {a.guardian_phone} · WhatsApp
                    </a>
                  ) : (
                    <span className="text-muted-foreground">no guardian number</span>
                  )}
                </div>
              ))}
            </CardContent>
          </Card>
        </section>
      ))}
    </div>
  );
}
