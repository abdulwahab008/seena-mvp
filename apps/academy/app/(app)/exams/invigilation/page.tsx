import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { getExamOfficeScope, one } from '@/lib/exams/office-scope';
import { AddDutyForm, ExclusionForm, RemoveDutyButton, RemoveExclusionButton, RunPanel } from './invigilation-board';

/**
 * FR-I10. Invigilation duties for a term's datesheet: auto-assignment (fewest
 * duties first, never your own subject, never over the cap, never on leave or
 * the exclusion list), the substitution tasks that leave raises, and every
 * member's own duties. A paper that cannot be staffed is reported by name.
 */
type SearchParams = { term?: string };

const fmt = (iso: string, tz: string) =>
  new Date(iso).toLocaleString('en-GB', { timeZone: tz, weekday: 'short', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });

export default async function InvigilationPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const scope = await getExamOfficeScope(supabase);

  const header = (
    <div>
      <h1 className="text-2xl font-semibold">Invigilation duties</h1>
      <p className="text-sm text-muted-foreground">
        FR-I10 — assign invigilators fairly: nobody invigilates a subject they teach to that class, the load is spread evenly, and staff on leave are skipped.
      </p>
    </div>
  );

  // Everyone, teachers included, sees their own duties.
  const { data: mine } = await supabase
    .from('invigilation_duty')
    .select('id, status, slot:datesheet_slot_id(start_at, end_at, exam_subject:exam_subject_id(class_subject:class_subject_id(class_level:class_level_id(name_en), subject:subject_id(name_en))))')
    .eq('staff_id', scope.userId)
    .neq('status', 'cancelled');
  const myDuties = (mine ?? [])
    .map((d) => {
      const slot = one(d.slot);
      const es = slot ? one(slot.exam_subject) : null;
      const cs = es ? one(es.class_subject) : null;
      return { id: d.id, status: d.status, start: slot?.start_at ?? '', end: slot?.end_at ?? '', label: `${one(cs?.class_level)?.name_en ?? ''} · ${one(cs?.subject)?.name_en ?? ''}` };
    })
    .sort((a, b) => a.start.localeCompare(b.start));

  const tz = scope.campus?.timezone ?? 'Asia/Karachi';
  const myCard = (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">My duties</CardTitle>
      </CardHeader>
      <CardContent className="space-y-1 text-sm" data-testid="my-duties">
        {myDuties.length === 0 && <p className="text-muted-foreground">You have no invigilation duties.</p>}
        {myDuties.map((d) => (
          <p key={d.id} data-testid="my-duty">
            {fmt(d.start, tz)} – {new Date(d.end).toLocaleTimeString('en-GB', { timeZone: tz, hour: '2-digit', minute: '2-digit' })} · {d.label}
            {d.status === 'substitution_needed' ? ' (substitute being arranged)' : ''}
          </p>
        ))}
      </CardContent>
    </Card>
  );

  if (!scope.campus || !scope.session || !scope.canWrite) {
    return (
      <div className="space-y-6">
        {header}
        {myCard}
        {scope.canWrite === false && <p className="text-sm text-muted-foreground">Running the roster is the exam office&rsquo;s.</p>}
      </div>
    );
  }
  const campus = scope.campus;

  const { data: terms } = await supabase.from('exam_term').select('id, name').eq('campus_id', campus.id).eq('session_id', scope.session.id).order('sequence');
  const term = (terms ?? []).find((t) => t.id === sp.term) ?? terms?.[0] ?? null;
  const { data: datesheet } = term ? await supabase.from('datesheet').select('id, title, status').eq('exam_term_id', term.id).eq('campus_id', campus.id).maybeSingle() : { data: null };

  const { data: slotRows } = datesheet
    ? await supabase
        .from('datesheet_slot')
        .select('id, start_at, end_at, invigilators_required, exam_subject:exam_subject_id(class_subject:class_subject_id(class_level:class_level_id(name_en), subject:subject_id(name_en)))')
        .eq('datesheet_id', datesheet.id)
        .order('start_at')
    : { data: [] };
  const slots = (slotRows ?? []).map((s) => {
    const es = one(s.exam_subject);
    const cs = es ? one(es.class_subject) : null;
    return { id: s.id, start: s.start_at, end: s.end_at, required: s.invigilators_required, label: `${one(cs?.class_level)?.name_en ?? ''} · ${one(cs?.subject)?.name_en ?? ''}` };
  });
  const slotLabels = Object.fromEntries(slots.map((s) => [s.id, `${s.label} (${fmt(s.start, tz)})`]));

  const { data: staffRows } = await supabase.from('staff').select('user_id, full_name, employment_status').eq('employment_status', 'active').not('user_id', 'is', null).order('full_name');
  const staff = (staffRows ?? []).map((s) => ({ userId: s.user_id as string, name: s.full_name }));
  const staffName = new Map(staff.map((s) => [s.userId, s.name]));

  const slotIds = slots.map((s) => s.id);
  const { data: dutyRows } = slotIds.length ? await supabase.from('invigilation_duty').select('id, datesheet_slot_id, staff_id, status').in('datesheet_slot_id', slotIds).neq('status', 'cancelled') : { data: [] };
  const { data: tasks } = slotIds.length
    ? await supabase.from('invigilation_substitution_task').select('id, reason, status, duty:duty_id(datesheet_slot_id, staff_id)').eq('status', 'open')
    : { data: [] };
  const { data: exclusions } = term ? await supabase.from('invigilation_constraint').select('id, staff_id, exclude_date, reason').eq('exam_term_id', term.id).order('exclude_date') : { data: [] };

  const counts = new Map<string, number>();
  for (const d of dutyRows ?? []) if (d.status === 'assigned') counts.set(d.staff_id, (counts.get(d.staff_id) ?? 0) + 1);

  return (
    <div className="space-y-6">
      {header}
      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Exam term</span>
          <select name="term" defaultValue={term?.id} className="h-9 rounded-md border bg-background px-2">
            {(terms ?? []).map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
        <span className="text-muted-foreground">{campus.name}</span>
      </form>

      {!datesheet ? (
        <p className="text-sm text-muted-foreground">Build the datesheet for this term first; invigilators are assigned to its papers.</p>
      ) : (
        <>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">{datesheet.title}</CardTitle>
            </CardHeader>
            <CardContent>
              <RunPanel datesheetId={datesheet.id} slotLabels={slotLabels} />
            </CardContent>
          </Card>

          {(tasks ?? []).length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Substitution tasks</CardTitle>
              </CardHeader>
              <CardContent className="space-y-1 text-sm" data-testid="substitution-tasks">
                {(tasks ?? []).map((t) => {
                  const duty = one(t.duty);
                  return (
                    <p key={t.id} data-testid="substitution-task">
                      {staffName.get(duty?.staff_id ?? '') ?? 'Staff'} — {slotLabels[duty?.datesheet_slot_id ?? ''] ?? 'paper'}: {t.reason === 'staff_on_leave' ? 'on approved leave' : 'on the exclusion list'}. Add a replacement below.
                    </p>
                  );
                })}
              </CardContent>
            </Card>
          )}

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Roster</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4 text-sm" data-testid="roster">
              {slots.length === 0 && <p className="text-muted-foreground">The datesheet has no papers yet.</p>}
              {slots.map((s) => {
                const duties = (dutyRows ?? []).filter((d) => d.datesheet_slot_id === s.id);
                const filled = duties.filter((d) => d.status === 'assigned').length;
                return (
                  <div key={s.id} className="space-y-2 border-b pb-3" data-testid="roster-slot">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="font-medium">
                        {s.label} · {fmt(s.start, tz)}
                      </span>
                      <Badge variant={filled >= s.required ? 'success' : 'outline'} data-testid="slot-fill">
                        {filled} of {s.required}
                      </Badge>
                    </div>
                    <ul className="space-y-1">
                      {duties.map((d) => (
                        <li key={d.id} className="flex items-center justify-between gap-2" data-testid="duty-row">
                          <span>
                            {staffName.get(d.staff_id) ?? 'Staff'} <span className="text-xs text-muted-foreground">({counts.get(d.staff_id) ?? 0} duties)</span>
                            {d.status === 'substitution_needed' && <span className="ml-2 text-xs text-destructive">needs a substitute</span>}
                          </span>
                          <RemoveDutyButton dutyId={d.id} />
                        </li>
                      ))}
                    </ul>
                    <AddDutyForm slotId={s.id} staff={staff} />
                  </div>
                );
              })}
            </CardContent>
          </Card>
        </>
      )}

      {term && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Exclusion list</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <p className="text-muted-foreground">
              Staff who cannot invigilate on a date. This works whether or not HR leave is recorded; approved leave is also honoured automatically.
            </p>
            <ul className="space-y-1" data-testid="exclusion-list">
              {(exclusions ?? []).length === 0 && <li className="text-muted-foreground">No exclusions.</li>}
              {(exclusions ?? []).map((x) => (
                <li key={x.id} className="flex items-center justify-between gap-2" data-testid="exclusion-row">
                  <span>
                    {staffName.get(x.staff_id) ?? 'Staff'} — {x.exclude_date ?? 'one paper'} — {x.reason}
                  </span>
                  <RemoveExclusionButton id={x.id} />
                </li>
              ))}
            </ul>
            <ExclusionForm examTermId={term.id} staff={staff} />
          </CardContent>
        </Card>
      )}

      {myCard}
    </div>
  );
}
