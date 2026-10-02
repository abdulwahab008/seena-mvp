import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { getExamOfficeScope, one } from '@/lib/exams/office-scope';
import type { SeatingChart } from '@/lib/exams/seating-html';
import { SlotPlanner } from './seating-planner';

/**
 * FR-I09. Seating plans for a term's datesheet. Pick a paper, generate its plan
 * (sections interleaved so benchmates are never from one section; set letters
 * alternate when the paper has several sets) and print the hall chart and seat
 * slips. Regeneration is stable: nobody who already has a seat moves.
 */
type SearchParams = { term?: string; slot?: string };

const fmt = (iso: string, tz: string) => new Date(iso).toLocaleString('en-GB', { timeZone: tz, weekday: 'short', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
const PALETTE = ['bg-blue-100', 'bg-green-100', 'bg-red-100', 'bg-yellow-100', 'bg-purple-100', 'bg-orange-100'];

export default async function SeatingPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const scope = await getExamOfficeScope(supabase);

  const header = (
    <div>
      <h1 className="text-2xl font-semibold">Seating plans</h1>
      <p className="text-sm text-muted-foreground">
        FR-I09 — generate a seating plan per paper: candidates of one section never sit side by side, adjacent seats alternate paper sets, and a regeneration keeps everyone who already has a seat.
      </p>
    </div>
  );
  if (!scope.campus || !scope.session) return <div className="space-y-6">{header}<p className="text-sm text-muted-foreground">No active campus or current session found.</p></div>;
  const campus = scope.campus;
  const tz = campus.timezone;

  const { data: terms } = await supabase.from('exam_term').select('id, name').eq('campus_id', campus.id).eq('session_id', scope.session.id).order('sequence');
  const term = (terms ?? []).find((t) => t.id === sp.term) ?? terms?.[0] ?? null;
  const { data: datesheet } = term ? await supabase.from('datesheet').select('id, title').eq('exam_term_id', term.id).eq('campus_id', campus.id).maybeSingle() : { data: null };

  const { data: slotRows } = datesheet
    ? await supabase
        .from('datesheet_slot')
        .select('id, exam_subject_id, start_at, end_at, hall_id, hall:hall_id(name), exam_subject:exam_subject_id(class_subject:class_subject_id(class_level:class_level_id(name_en), subject:subject_id(name_en)))')
        .eq('datesheet_id', datesheet.id)
        .order('start_at')
    : { data: [] };
  const slots = (slotRows ?? []).map((s) => {
    const cs = one(one(s.exam_subject)?.class_subject);
    return { id: s.id, examSubjectId: s.exam_subject_id, start: s.start_at, hallId: s.hall_id, hallName: one(s.hall)?.name ?? null, label: `${one(cs?.class_level)?.name_en ?? ''} · ${one(cs?.subject)?.name_en ?? ''}` };
  });
  const { data: warnRows } = datesheet ? await supabase.rpc('fn_datesheet_warnings', { p_datesheet_id: datesheet.id }) : { data: [] };
  const candidatesBySlot = new Map<string, number>();
  for (const w of warnRows ?? []) {
    const hit = ((w.warnings ?? []) as unknown as { candidates?: number }[]).find((x) => typeof x.candidates === 'number');
    if (hit?.candidates !== undefined) candidatesBySlot.set(w.slot_id, hit.candidates);
  }
  const { data: allocRows } = slots.length ? await supabase.from('exam_seat_allocation').select('slot_id').in('slot_id', slots.map((s) => s.id)) : { data: [] };
  const seated = new Map<string, number>();
  for (const a of allocRows ?? []) seated.set(a.slot_id, (seated.get(a.slot_id) ?? 0) + 1);
  const { data: setGroups } = await supabase.from('exam_paper_set_group').select('exam_subject_id, set_count');
  const setCountOf = new Map((setGroups ?? []).map((g) => [g.exam_subject_id, g.set_count]));

  const selected = slots.find((s) => s.id === sp.slot) ?? slots[0] ?? null;
  const { data: chartData } = selected ? await supabase.rpc('fn_seating_chart', { p_slot_id: selected.id }) : { data: null };
  const chart = chartData as unknown as SeatingChart | null;
  const { data: violations } = selected ? await supabase.rpc('fn_seating_violations', { p_slot_id: selected.id }) : { data: [] };
  const { data: seatRows } = selected?.hallId ? await supabase.from('exam_hall_seat').select('row_no, seat_no, is_available').eq('hall_id', selected.hallId) : { data: [] };
  const unusable = new Set((seatRows ?? []).filter((s) => !s.is_available).map((s) => `${s.row_no}:${s.seat_no}`));
  const bySeat = new Map((chart?.allocations ?? []).map((a) => [`${a.row_no}:${a.seat_no}`, a]));
  const sectionIds = [...new Set((chart?.allocations ?? []).map((a) => a.section_id))];

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
      </form>

      {!datesheet ? (
        <p className="text-sm text-muted-foreground">Build the datesheet for this term first; plans are made per paper.</p>
      ) : (
        <>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Papers</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2 text-sm" data-testid="seating-slots">
              {slots.length === 0 && <p className="text-muted-foreground">The datesheet has no papers yet.</p>}
              {slots.map((s) => {
                const need = candidatesBySlot.get(s.id);
                const have = seated.get(s.id) ?? 0;
                return (
                  <div key={s.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="seating-slot">
                    <a className={s.id === selected?.id ? 'font-medium underline' : 'underline'} href={`/exams/seating?term=${term?.id}&slot=${s.id}`}>
                      {s.label} · {fmt(s.start, tz)}
                    </a>
                    <span className="flex items-center gap-2">
                      <span className="text-muted-foreground">{s.hallName ?? 'no hall'}</span>
                      <Badge variant={have > 0 && have === need ? 'success' : 'outline'}>
                        {have}
                        {need !== undefined ? ` of ${need}` : ''} seated
                      </Badge>
                    </span>
                  </div>
                );
              })}
            </CardContent>
          </Card>

          {selected && chart && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">
                  {selected.label} — {selected.hallName ?? 'no hall'}
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-4">
                {scope.canWrite ? (
                  <SlotPlanner slotId={selected.id} examSubjectId={selected.examSubjectId} hallId={selected.hallId} setCount={setCountOf.get(selected.examSubjectId) ?? 1} />
                ) : (
                  <p className="text-sm text-muted-foreground">Generating plans is the exam office&rsquo;s.</p>
                )}
                {(chart.allocations.length ?? 0) > 0 && (
                  <p className="text-sm" data-testid="violation-summary">
                    {(violations ?? []).length === 0 ? 'No adjacency violations.' : `${(violations ?? []).length} adjacency violation(s): ${(violations ?? []).map((v) => `${v.seat_a}/${v.seat_b}`).join(', ')}`}
                  </p>
                )}
                {chart.hall && chart.allocations.length > 0 && (
                  <div className="overflow-x-auto">
                    <table className="border-collapse text-xs" data-testid="seat-map">
                      <tbody>
                        {Array.from({ length: chart.hall.rows }, (_, r) => (
                          <tr key={r}>
                            <th className="px-1 text-muted-foreground">R{r + 1}</th>
                            {Array.from({ length: chart.hall!.seats_per_row }, (_, s) => {
                              const a = bySeat.get(`${r + 1}:${s + 1}`);
                              const off = unusable.has(`${r + 1}:${s + 1}`);
                              return (
                                <td key={s} className={`h-9 w-14 border text-center ${a ? PALETTE[sectionIds.indexOf(a.section_id) % PALETTE.length] : off ? 'bg-muted line-through' : ''}`} data-testid={a ? 'seat-taken' : undefined} title={a ? `${a.name_en} (GR ${a.gr_number})` : off ? 'Out of use' : 'Empty'}>
                                  {a ? (
                                    <>
                                      <span className="block font-medium">{a.gr_number.replace(/^GR-?/, '')}</span>
                                      <span className="block text-[10px] text-muted-foreground">
                                        {a.section_name}
                                        {chart.set_count > 1 ? ` · ${a.set_code}` : ''}
                                      </span>
                                    </>
                                  ) : null}
                                </td>
                              );
                            })}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </CardContent>
            </Card>
          )}
        </>
      )}
    </div>
  );
}
