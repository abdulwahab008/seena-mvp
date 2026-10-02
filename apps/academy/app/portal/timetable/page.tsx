import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { WEEKDAY_LABELS } from '@/lib/validation';

const SCHOOL_WEEKDAYS = [1, 2, 3, 4, 5, 6]; // Monday–Saturday; Sunday is the weekly off day.

type SlotRow = {
  slot_id: string;
  weekday: number;
  period_no: number;
  subject_code: string;
  subject_name_en: string;
  subject_name_ur: string | null;
  teacher_name: string | null;
  room_code: string | null;
};

export default async function PortalTimetablePage({ searchParams }: { searchParams: Promise<{ section?: string }> }) {
  const { section: sectionParam } = await searchParams;
  const supabase = await supabaseServer();

  // AC: a parent with multiple children gets a child selector, scoped to
  // only the signed-in guardian's own active enrolments (enrolment_parent_
  // read_own_children, FR-C11) — same pattern as /portal/homework.
  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('section_id, student:student_id(id, name_en), class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active');

  type Child = { studentId: string; studentName: string; sectionId: string; sectionLabel: string };
  const children: Child[] = (enrolments ?? [])
    .map((e) => {
      const student = Array.isArray(e.student) ? e.student[0] : e.student;
      const section = Array.isArray(e.class_section) ? e.class_section[0] : e.class_section;
      const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
      if (!student || !section) return null;
      return {
        studentId: student.id,
        studentName: student.name_en,
        sectionId: e.section_id,
        sectionLabel: `${level?.name_en ?? ''} · ${section.name}`,
      };
    })
    .filter((c): c is Child => !!c);

  const selectedSectionId = sectionParam ?? children[0]?.sectionId;

  // AC: only a Published timetable is ever visible to a parent —
  // timetable_slot_parent_read enforces that; superseded history is
  // filtered out here so a stale timetable never renders as current.
  const { data: rows } = selectedSectionId
    ? await supabase
        .from('v_section_timetable')
        .select('slot_id, weekday, period_no, subject_code, subject_name_en, subject_name_ur, teacher_name, room_code, version_status, version_validity')
        .eq('section_id', selectedSectionId)
        .eq('version_status', 'PUBLISHED')
    : { data: [] as never[] };

  const slots = (rows ?? []) as unknown as SlotRow[];
  const periods = Array.from(new Set(slots.map((s) => s.period_no))).sort((a, b) => a - b);
  const slotAt = (weekday: number, periodNo: number) => slots.find((s) => s.weekday === weekday && s.period_no === periodNo);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Timetable</h2>
        <p className="text-sm text-muted-foreground">FR-F11 — your child&apos;s published weekly timetable.</p>
      </div>

      {children.length === 0 ? (
        <p className="text-sm text-muted-foreground">No enrolled child found on this account.</p>
      ) : (
        <>
          {children.length > 1 && (
            <div className="flex flex-wrap gap-2" data-testid="timetable-child-selector">
              {children.map((c) => (
                <Link
                  key={c.studentId}
                  href={`/portal/timetable?section=${c.sectionId}`}
                  data-testid={`timetable-child-${c.studentName}`}
                  className={`rounded-full border px-3 py-1 text-sm ${
                    c.sectionId === selectedSectionId ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'
                  }`}
                >
                  {c.studentName} ({c.sectionLabel})
                </Link>
              ))}
            </div>
          )}

          {slots.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="timetable-empty">
              No published timetable yet for this section.
            </p>
          ) : (
            <div className="overflow-x-auto rounded-lg border">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b bg-muted/50">
                    <th className="p-2 text-left font-medium">Period</th>
                    {SCHOOL_WEEKDAYS.map((w) => (
                      <th key={w} className="p-2 text-left font-medium">
                        {WEEKDAY_LABELS[w]}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {periods.map((periodNo) => (
                    <tr key={periodNo} className="border-b last:border-0">
                      <td className="p-2 font-medium text-muted-foreground">{periodNo}</td>
                      {SCHOOL_WEEKDAYS.map((w) => {
                        const slot = slotAt(w, periodNo);
                        return (
                          <td key={w} data-testid={`portal-grid-cell-${w}-${periodNo}`} className="p-2 align-top">
                            {slot ? (
                              <div className="space-y-0.5">
                                <p className="font-medium">{slot.subject_name_en}</p>
                                {slot.teacher_name && <p className="text-xs text-muted-foreground">{slot.teacher_name}</p>}
                                {slot.room_code && <p className="text-xs text-muted-foreground">{slot.room_code}</p>}
                              </div>
                            ) : (
                              <span className="text-xs text-muted-foreground">Free</span>
                            )}
                          </td>
                        );
                      })}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
