'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type RoleActionState = { error: string | null; holderCount?: number };

/**
 * FR-A11. Every one of these maps to a server-side refusal — the picker only
 * offering permissions the caller holds is a convenience, and
 * create_custom_role/assign_custom_role re-assert the superset themselves.
 */
function rpcMessage(message: string, details?: string | null): string {
  if (message.includes('PERMISSION_ESCALATION'))
    return details
      ? `You cannot grant a permission you do not hold yourself: ${details.split(',').join(', ')}.`
      : 'You cannot grant a permission you do not hold yourself.';
  if (message.includes('ROLE_IN_USE'))
    return `This role is still held by ${details ?? 'some'} user(s). Reassign them first.`;
  if (message.includes('ROLE_CODE_TAKEN')) return 'A role with that name already exists.';
  if (message.includes('ROLE_CODE_RESERVED')) return 'That name is reserved for a built-in role.';
  if (message.includes('ROLE_NAME_INVALID')) return 'Give the role a name between 2 and 60 characters.';
  if (message.includes('PERMISSION_UNKNOWN')) return 'One of those permissions is not in the catalogue.';
  if (message.includes('ROLE_IMMUTABLE')) return 'Built-in roles cannot be edited or deleted.';
  if (message.includes('ROLE_NOT_FOUND')) return 'That role no longer exists.';
  if (message.includes('USER_NOT_FOUND')) return 'That user is not in your school.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to manage roles.';
  return 'Could not save the role.';
}

export async function createRole(_prev: RoleActionState, formData: FormData): Promise<RoleActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_custom_role', {
    p_name: String(formData.get('name') ?? ''),
    p_permission_codes: formData.getAll('permissions').map(String),
  });
  if (error) return { error: rpcMessage(error.message, error.details) };
  revalidatePath('/roles');
  return { error: null };
}

export async function updateRole(_prev: RoleActionState, formData: FormData): Promise<RoleActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('update_custom_role', {
    p_role_id: String(formData.get('roleId') ?? ''),
    p_name: String(formData.get('name') ?? ''),
    p_permission_codes: formData.getAll('permissions').map(String),
  });
  if (error) return { error: rpcMessage(error.message, error.details) };
  revalidatePath('/roles');
  return { error: null };
}

export async function deleteRole(_prev: RoleActionState, formData: FormData): Promise<RoleActionState> {
  const supabase = await supabaseServer();
  const roleId = String(formData.get('roleId') ?? '');
  const { error } = await supabase.rpc('delete_custom_role', { p_role_id: roleId });
  if (error) {
    const holderCount = error.message.includes('ROLE_IN_USE') ? Number(error.details) : undefined;
    return { error: rpcMessage(error.message, error.details), holderCount };
  }
  revalidatePath('/roles');
  return { error: null };
}

export async function reassignHolders(_prev: RoleActionState, formData: FormData): Promise<RoleActionState> {
  const supabase = await supabaseServer();
  const to = String(formData.get('toRoleId') ?? '');
  const { error } = await supabase.rpc('reassign_role_holders', {
    p_from_role_id: String(formData.get('fromRoleId') ?? ''),
    p_to_role_id: to === '' ? undefined : to,
  });
  if (error) return { error: rpcMessage(error.message, error.details) };
  revalidatePath('/roles');
  return { error: null };
}
