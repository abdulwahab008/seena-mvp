'use server';

import { revalidatePath } from 'next/cache';
import {
  createBellTemplateSchema,
  createBellCalendarRuleSchema,
  createDateRangeBellRuleSchema,
  updateBellRuleDatesSchema,
} from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

function mapError(message: string): string {
  if (message.startsWith('BELL_PERIOD_OVERLAP')) return message.replace('BELL_PERIOD_OVERLAP: segments', 'Segments') + ' overlap.';
  if (message.includes('BELL_TEMPLATE_EMPTY')) return 'Add at least one segment.';
  if (message.includes('BELL_TEMPLATE_CODE_DUPLICATE')) return 'A template with this code already exists for this campus and shift.';
  if (message.includes('BELL_TEMPLATE_LOCKED')) return 'This template is locked because it is referenced by a published timetable.';
  if (message.includes('BELL_TEMPLATE_NOT_FOUND')) return 'Template not found.';
  if (message.includes('BELL_PERIOD_NOT_FOUND')) return 'Segment not found.';
  if (message.includes('BELL_PERIOD_TIME_ORDER_INVALID')) return 'End time must be after start time.';
  if (message.includes('BELL_RULE_WEEKDAY_PRECEDENCE_DUPLICATE')) return 'A rule already exists for this weekday and precedence.';
  if (message.includes('BELL_RULE_SHAPE_INVALID')) return 'Choose a weekday for this rule.';
  if (message.includes('BELL_RULE_WEEKDAY_INVALID')) return 'Choose a valid weekday.';
  if (message.includes('BELL_RULE_DATE_RANGE_OVERLAP'))
    return 'Another override of the same precedence already covers part of this date range.';
  if (message.includes('BELL_RULE_DATE_ORDER_INVALID')) return 'End date must not precede the start date.';
  if (message.includes('BELL_RULE_NOT_DATE_RANGED')) return 'This rule has no date range to correct.';
  if (message.includes('BELL_RULE_NOT_FOUND')) return 'Rule not found.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Something went wrong.';
}

export async function createBellTemplate(campusId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const raw = formData.get('segments');
  const parsed = createBellTemplateSchema.safeParse({
    shift: formData.get('shift'),
    code: formData.get('code'),
    name: formData.get('name'),
    segments: raw ? JSON.parse(raw as string) : [],
    isDefault: formData.get('isDefault') === 'on',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_bell_template', {
    p_campus_id: campusId,
    p_shift: parsed.data.shift,
    p_code: parsed.data.code,
    p_name: parsed.data.name,
    p_segments: parsed.data.segments.map((s) => ({ kind: s.kind, start_time: s.startTime, end_time: s.endTime })),
    p_is_default: parsed.data.isDefault ?? false,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/bell-templates');
  return { error: null };
}

export async function setBellTemplateDefault(id: string, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_bell_template_default', { p_id: id });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/bell-templates');
  return { error: null };
}

export async function createBellCalendarRule(campusId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createBellCalendarRuleSchema.safeParse({
    shift: formData.get('shift'),
    bellTemplateId: formData.get('bellTemplateId'),
    weekday: formData.get('weekday'),
    precedence: formData.get('precedence') || undefined,
    note: formData.get('note') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_bell_calendar_rule', {
    p_campus_id: campusId,
    p_shift: parsed.data.shift,
    p_bell_template_id: parsed.data.bellTemplateId,
    p_weekday: parsed.data.weekday,
    p_precedence: parsed.data.precedence,
    p_note: parsed.data.note,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/bell-templates');
  return { error: null };
}

export async function createDateRangeBellRule(campusId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createDateRangeBellRuleSchema.safeParse({
    shift: formData.get('shift'),
    bellTemplateId: formData.get('bellTemplateId'),
    weekday: formData.get('weekday'),
    dateFrom: formData.get('dateFrom'),
    dateTo: formData.get('dateTo'),
    precedence: formData.get('precedence') || undefined,
    note: formData.get('note') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_bell_calendar_rule', {
    p_campus_id: campusId,
    p_shift: parsed.data.shift,
    p_bell_template_id: parsed.data.bellTemplateId,
    p_weekday: parsed.data.weekday ?? undefined,
    p_date_from: parsed.data.dateFrom,
    p_date_to: parsed.data.dateTo ?? undefined,
    p_precedence: parsed.data.precedence,
    p_note: parsed.data.note,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/bell-templates');
  return { error: null };
}

// FR-F03 AC2: the Ruet-e-Hilal announcement lands the night before, so
// the range gets corrected by a day after it is already active. Nothing
// downstream is rewritten — resolve_bell_template() is read-time and
// pure, so attendance already marked under the old range is untouched.
export async function updateBellRuleDates(id: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = updateBellRuleDatesSchema.safeParse({
    dateFrom: formData.get('dateFrom'),
    dateTo: formData.get('dateTo'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('update_bell_calendar_rule_dates', {
    p_id: id,
    p_date_from: parsed.data.dateFrom,
    p_date_to: parsed.data.dateTo ?? undefined,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/bell-templates');
  return { error: null };
}

export async function deleteBellCalendarRule(id: string, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_bell_calendar_rule', { p_id: id });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/bell-templates');
  return { error: null };
}
