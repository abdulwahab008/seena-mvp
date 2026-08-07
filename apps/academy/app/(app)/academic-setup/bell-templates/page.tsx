import { supabaseServer } from '@/lib/supabase/server';
import { CreateBellTemplateForm } from './create-bell-template-form';
import { BellTemplateList, type BellTemplateRow } from './bell-template-list';
import { BellCalendarRules, type CalendarRuleRow } from './bell-calendar-rules';

const SHIFTS = ['MORNING', 'AFTERNOON'] as const;

export default async function BellTemplatesPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  const { data: templates } = campusId
    ? await supabase
        .from('bell_template')
        .select('id, shift, code, name, is_default, is_locked, bell_period(id, segment_ordinal, period_no, kind, start_time, end_time)')
        .eq('campus_id', campusId)
        .order('shift')
        .order('code')
    : { data: [] as never[] };

  const { data: rules } = campusId
    ? await supabase
        .from('bell_calendar_rule')
        .select('id, shift, weekday, precedence, note, bell_template(code, name)')
        .eq('campus_id', campusId)
        .order('shift')
        .order('weekday')
    : { data: [] as never[] };

  const rows = (templates ?? []) as unknown as BellTemplateRow[];
  const ruleRows = (rules ?? []) as unknown as CalendarRuleRow[];
  const shiftsWithoutDefault = SHIFTS.filter((s) => !rows.some((t) => t.shift === s && t.is_default));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Bell Templates</h1>
        <p className="text-sm text-muted-foreground">
          FR-F01 — campus bell timings every timetable, attendance window and printed sheet will use.
        </p>
      </div>
      {!campusId ? (
        <p className="text-sm text-muted-foreground">No active campus found.</p>
      ) : (
        <>
          {shiftsWithoutDefault.length > 0 && (
            <p data-testid="no-default-banner" className="rounded-md border border-amber-400 bg-amber-50 p-3 text-sm text-amber-900">
              No default template set for: {shiftsWithoutDefault.join(', ')}. The timetable builder will refuse to start for
              these shifts until one is nominated.
            </p>
          )}
          <CreateBellTemplateForm campusId={campusId} />
          <BellTemplateList templates={rows} />
          <BellCalendarRules campusId={campusId} templates={rows} rules={ruleRows} />
        </>
      )}
    </div>
  );
}
