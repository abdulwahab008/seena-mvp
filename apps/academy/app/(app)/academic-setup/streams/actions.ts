'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { campusBoardSchema, homeworkLoadSchema, homeworkNotificationCapSchema, markPrecisionSchema, sectionStreamSchema, streamSchema } from '@/lib/validation';
import { parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  uq_stream_tenant_code: 'A stream with this code already exists.',
  STREAM_IN_USE: 'Sections use this stream. Deactivate it instead, or take it off those sections first.',
  STREAM_NOT_FOUND: 'That stream was not found.',
  SECTION_NOT_FOUND: 'That section was not found.',
};
const done = (message: string): ActionResult => {
  revalidatePath('/academic-setup/streams');
  return { error: null, message };
};

export async function createStream(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(streamSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_stream', {
    p_code: p.data.code,
    p_name_en: p.data.nameEn,
    p_name_ur: p.data.nameUr ?? '',
    p_board: p.data.board,
    p_applies_from_ordinal: p.data.fromOrdinal,
  });
  return error ? { error: rpcError(error.message, MESSAGES) } : done('Stream added.');
}

export async function setStreamActive(id: string, active: boolean): Promise<ActionResult> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_stream_active', { p_id: id, p_is_active: active });
  return error ? { error: rpcError(error.message, MESSAGES) } : done(active ? 'Stream active.' : 'Stream deactivated.');
}

export async function deleteStream(id: string): Promise<ActionResult> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_stream', { p_id: id });
  return error ? { error: rpcError(error.message, MESSAGES) } : done('Stream deleted.');
}

export async function setSectionStream(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(sectionStreamSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_section_stream', { p_section_id: p.data.sectionId, p_stream_id: p.data.streamId || null });
  if (error) {
    if (error.message.includes('STREAM_NOT_OFFERED_FOR_CLASS')) return { error: 'This stream does not start until a later class.' };
    return { error: rpcError(error.message, MESSAGES) };
  }
  return done('Section stream saved.');
}

export async function setCampusBoard(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(campusBoardSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_campus_board', { p_campus_id: p.data.campusId, p_board: p.data.board });
  return error ? { error: rpcError(error.message, MESSAGES) } : done('Exam board saved.');
}

export async function setMarkPrecision(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(markPrecisionSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_mark_precision', { p_campus_id: p.data.campusId, p_precision: Number(p.data.precision) });
  return error ? { error: rpcError(error.message) } : done('Mark entry rule saved.');
}

export async function setHomeworkLoad(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(homeworkLoadSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { data: session } = await supabase
    .from('academic_session')
    .select('id')
    .eq('is_current', true)
    .or(`campus_id.eq.${p.data.campusId},campus_id.is.null`)
    .order('campus_id', { nullsFirst: false })
    .limit(1)
    .maybeSingle();
  if (!session) return { error: 'This campus has no current session.' };
  const { error } = await supabase.rpc('set_homework_load_policy', {
    p_campus_id: p.data.campusId,
    p_session_id: session.id,
    p_max_assignments_per_day: p.data.maxAssignments,
    p_max_minutes_per_day: p.data.maxMinutes,
  });
  return error ? { error: rpcError(error.message) } : done('Homework limit saved.');
}

export async function setHomeworkNotificationCap(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(homeworkNotificationCapSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_homework_notification_cap', { p_cap: p.data.cap });
  return error ? { error: rpcError(error.message) } : done('Daily message limit saved.');
}
