'use server';

import { revalidatePath } from 'next/cache';
import { createBellTemplateSchema } from '@/lib/validation';
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
