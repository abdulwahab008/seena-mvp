'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { mapRpcError, type ActionError } from '@/lib/rpc-action';
import { custodyAckSchema, custodyIssueSchema, custodyReturnSchema } from '@/lib/validation';

const MESSAGES: [string, string][] = [
  ['ASSET_IN_CUSTODY', 'This asset is already in someone\'s custody. Record its return first.'],
  ['ASSET_NOT_AVAILABLE', 'This asset cannot be issued: it is disposed, written off or in the workshop.'],
  ['ASSET_IN_REPAIR', 'This asset is in repair and cannot be issued.'],
  ['CUSTODIAN_NOT_FOUND', 'That custodian was not found.'],
  ['OTP_INVALID', 'That code is not right.'],
  ['OTP_EXPIRED', 'The code has expired. Ask for a new one.'],
  ['OTP_LOCKED', 'Too many wrong codes. Ask for a new one.'],
  ['CUSTODY_NOT_ACKNOWLEDGEABLE', 'This custody has already been acknowledged or returned.'],
  ['REFERENCE_REQUIRED', 'Enter the form or register reference.'],
  ['ALREADY_RETURNED', 'This asset has already been returned.'],
  ['RETURN_BEFORE_ISSUE', 'The return date cannot be before the issue date.'],
  ['ASSET_CLEARANCE_BLOCKED', 'Assets are still with this person.'],
  ['FORBIDDEN', 'You do not have permission for this step.'],
];
const first = (e: { issues: { message: string }[] } | undefined) => e?.issues[0]?.message ?? 'Invalid input.';

export async function issueCustodyAction(input: Record<string, string>): Promise<ActionError> {
  const p = custodyIssueSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const [type, id] = p.data.custodian.split(':') as ['department' | 'room' | 'staff', string];
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('issue_asset_custody', {
    p_asset_id: p.data.assetId,
    p_custodian_type: type,
    p_department_id: type === 'department' ? id : undefined,
    p_room_id: type === 'room' ? id : undefined,
    p_staff_id: type === 'staff' ? id : undefined,
    p_issued_on: p.data.issuedOn || undefined,
    p_remarks: p.data.remarks || undefined,
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets/custody');
  return { error: null };
}

export async function returnCustodyAction(input: Record<string, string>): Promise<ActionError> {
  const p = custodyReturnSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('return_asset_custody', {
    p_custody_id: p.data.custodyId,
    p_condition: p.data.condition,
    p_returned_on: p.data.returnedOn || undefined,
    p_remarks: p.data.remarks || undefined,
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets/custody');
  return { error: null };
}

export async function requestOtpAction(custodyId: string): Promise<ActionError> {
  if (!z.string().uuid().safeParse(custodyId).success) return { error: 'Invalid custody.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('request_custody_ack_otp', { p_custody_id: custodyId });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  return { error: null };
}

export async function acknowledgeCustodyAction(input: Record<string, string>): Promise<ActionError> {
  const p = custodyAckSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('acknowledge_asset_custody', {
    p_custody_id: p.data.custodyId,
    p_method: p.data.method,
    p_otp: p.data.otp || undefined,
    p_reference: p.data.reference || undefined,
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets/custody');
  return { error: null };
}

export async function clearanceCheckAction(staffId: string): Promise<{ error: string | null; cleared?: boolean; assets?: { tag_no: string; name: string }[] }> {
  if (!z.string().uuid().safeParse(staffId).success) return { error: 'Choose a staff member.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('staff_asset_clearance', { p_staff_id: staffId });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  const r = data as { cleared: boolean; assets: { tag_no: string; name: string }[] };
  return { error: null, cleared: r.cleared, assets: r.assets };
}
