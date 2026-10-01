'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { hostelSettingsSchema, visitorEntrySchema } from '@/lib/validation';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  CNIC_INVALID: 'CNIC must be 13 digits.',
  STUDENT_NOT_FOUND: 'No student has that GR number.',
  VISIT_NOT_FOUND: 'That visit was not found.',
  VISIT_ALREADY_CLOSED: 'This visitor has already been signed out.',
  PHOTO_PATH_INVALID: 'The photograph path is not valid for this visit.',
  SETTING_INVALID: 'That setting value is not valid.',
};

/** GR number -> student, for the gate form. */
export async function findStudent(gr: string): Promise<{ id: string; name: string; campusId: string; tenantId: string } | null> {
  const parsed = z.string().trim().min(1).max(40).safeParse(gr);
  if (!parsed.success) return null;
  const supabase = loose(await supabaseServer());
  const { data } = await supabase.from('student').select('id, name_en, campus_id, tenant_id').eq('gr_number', parsed.data).is('deleted_at', null).maybeSingle();
  const s = data as { id: string; name_en: string; campus_id: string; tenant_id: string } | null;
  return s ? { id: s.id, name: s.name_en, campusId: s.campus_id, tenantId: s.tenant_id } : null;
}

/** The relationship a CNIC has to the student, if it matches a guardian. */
export async function lookupRelationship(studentId: string, cnic: string): Promise<string | null> {
  if (!z.string().uuid().safeParse(studentId).success) return null;
  const supabase = loose(await supabaseServer());
  const { data } = await supabase.rpc('lookup_visitor_relationship', { p_student_id: studentId, p_visitor_cnic: cnic });
  return (data as string | null) ?? null;
}

export async function logVisit(values: Record<string, string>): Promise<ActionResult & { verified?: boolean }> {
  const p = parseValues(visitorEntrySchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data, error } = await supabase.rpc('log_hostel_visit', {
    p_student_id: p.data.studentId, p_visitor_name: p.data.visitorName, p_visitor_cnic: p.data.visitorCnic, p_relationship: p.data.relationship,
    p_phone: p.data.phone, p_photo_path: p.data.photoPath, p_visit_id: p.data.visitId,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/visitors');
  const verified = (data as { verified: boolean }).verified;
  return { error: null, verified, message: verified ? 'Visitor logged and verified as a guardian.' : 'Visitor logged. Not a recorded guardian: unverified.' };
}

export async function signOutVisitor(visitId: string): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(visitId).success) return { error: 'Invalid visit.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('exit_hostel_visit', { p_visit_id: visitId });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/visitors');
  return { error: null, message: 'Visitor signed out.' };
}

export async function saveHostelSettings(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelSettingsSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  for (const [key, value] of [
    ['hostel.visiting_close', p.data.visitingClose],
    ['hostel.visitor_retention_days', p.data.retentionDays],
    ['hostel.mess_notice_hours', p.data.messNoticeHours],
  ] as const) {
    const { error } = await supabase.rpc('set_hostel_setting', { p_key: key, p_value: value });
    if (error) return { error: rpcError(error.message, MESSAGES) };
  }
  revalidatePath('/hostel/visitors');
  return { error: null, message: 'Hostel settings saved.' };
}
