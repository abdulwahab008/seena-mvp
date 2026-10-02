import { supabaseServer } from '@/lib/supabase/server';
import { WEEKDAY_LABELS } from '@/lib/validation';
import { Clock } from 'lucide-react';

const SCHOOL_WEEKDAYS = [1, 2, 3, 4, 5, 6]; // Monday–Saturday

export default async function StudentTimetablePage() {
  const supabase = await supabaseServer();

  // Get student's enrolled section
  const { data: enrolment } = await supabase
    .from('enrolment')
    .select('id, section_id, class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active')
    .limit(1)
    .maybeSingle();

  const section = enrolment?.class_section
    ? (Array.isArray(enrolment.class_section) ? enrolment.class_section[0] : enrolment.class_section)
    : null;
  const level = section?.class_level
    ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level)
    : null;

  // Query published timetable slots
  const { data: rows } = enrolment?.section_id
    ? await supabase
        .from('v_section_timetable')
        .select('slot_id, weekday, period_no, subject_code, subject_name_en, teacher_name, room_code, version_status')
        .eq('section_id', enrolment.section_id)
        .eq('version_status', 'PUBLISHED')
    : { data: [] };

  const slots = (rows ?? []) as Array<{
    slot_id: string;
    weekday: number;
    period_no: number;
    subject_code: string;
    subject_name_en: string;
    teacher_name: string | null;
    room_code: string | null;
  }>;

  const periods = Array.from(new Set(slots.map((s) => s.period_no))).sort((a, b) => a - b);
  const byPeriodAndDay = new Map<string, (typeof slots)[number]>();
  for (const s of slots) {
    byPeriodAndDay.set(`${s.period_no}:${s.weekday}`, s);
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-bold tracking-tight">Class Timetable</h2>
          <p className="text-sm text-muted-foreground">
            {level ? `${level.name_en} · ` : ''}{section ? `Section ${section.name}` : 'Enrolled Class'}
          </p>
        </div>
      </div>

      {slots.length === 0 ? (
        <div className="rounded-lg border bg-card p-12 text-center text-muted-foreground">
          <Clock className="mx-auto h-10 w-10 mb-3 opacity-40" />
          <p className="font-medium">No published timetable available yet.</p>
          <p className="text-xs mt-1">Please check back once the timetable is published by your school.</p>
        </div>
      ) : (
        <div className="overflow-x-auto rounded-lg border bg-card shadow-sm">
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="border-b bg-muted/50 text-left">
                <th className="p-3 font-semibold text-muted-foreground">Period</th>
                {SCHOOL_WEEKDAYS.map((w) => (
                  <th key={w} className="p-3 font-semibold text-muted-foreground min-w-[120px]">
                    {WEEKDAY_LABELS[w] ?? `Day ${w}`}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {periods.map((p) => (
                <tr key={p} className="border-b last:border-b-0 hover:bg-muted/20">
                  <td className="p-3 font-medium text-muted-foreground">Period {p}</td>
                  {SCHOOL_WEEKDAYS.map((w) => {
                    const slot = byPeriodAndDay.get(`${p}:${w}`);
                    if (!slot) {
                      return (
                        <td key={w} className="p-3 text-muted-foreground/40 text-xs">
                          —
                        </td>
                      );
                    }
                    return (
                      <td key={w} className="p-3">
                        <div className="font-semibold text-foreground">{slot.subject_name_en}</div>
                        <div className="text-xs text-muted-foreground">
                          {slot.room_code ? `Room ${slot.room_code}` : ''}
                          {slot.room_code && slot.teacher_name ? ' · ' : ''}
                          {slot.teacher_name ?? ''}
                        </div>
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
