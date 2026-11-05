'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { STAFF_ROLES } from '@/lib/staff-roles';
import { deliverInvitation, type InviteDelivery } from '@/lib/staff-invite';
import { siteUrl } from '@/lib/auth/recovery';

const CORE_STAFF_ROLES = STAFF_ROLES;

const InviteSchema = z.object({
  email: z.string().email('Must be a valid email address'),
  role: z.enum(CORE_STAFF_ROLES),
});

export type InviteState = { error: string | null; delivery?: InviteDelivery | null };

export async function inviteStaff(campusId: string, _prev: InviteState, formData: FormData): Promise<InviteState> {
  const parsed = InviteSchema.safeParse({ email: formData.get('email'), role: formData.get('role') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data: invitationId, error } = await supabase.rpc('invite_user', {
    p_email: parsed.data.email,
    p_role: parsed.data.role,
    p_campus_ids: [campusId],
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Your role cannot invite someone as this role.' };
    return { error: 'Could not create the invitation.' };
  }

  const delivery = await deliverInvitation(invitationId);
  revalidatePath('/staff');
  return { error: null, delivery };
}

// Only someone who could have created the invitation may see its link or change it.
async function manageableInvitation(invitationId: string): Promise<string | null> {
  const supabase = await supabaseServer();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return 'You are not signed in.';
  const { data: me } = await supabase.from('app_user').select('tenant_id, app_role').eq('user_id', auth.user.id).maybeSingle();
  if (!me || !['owner', 'principal', 'super_admin'].includes(me.app_role)) return 'You do not have permission to manage invitations.';
  const { data: inv } = await supabaseServiceRole().from('tenant_invitation').select('tenant_id, accepted_at').eq('id', invitationId).maybeSingle();
  if (!inv || inv.tenant_id !== me.tenant_id) return 'Invitation not found.';
  if (inv.accepted_at) return 'This invitation has already been accepted.';
  return null;
}

export async function getInvitationLink(invitationId: string): Promise<{ error: string | null; delivery?: InviteDelivery | null }> {
  const denied = await manageableInvitation(invitationId);
  if (denied) return { error: denied };
  const { data } = await supabaseServiceRole().from('tenant_invitation').select('token').eq('id', invitationId).single();
  return { error: null, delivery: { link: `${siteUrl()}/accept-invite/${data?.token}`, emailed: false, note: null } };
}

export async function resendInvitation(invitationId: string): Promise<{ error: string | null; delivery?: InviteDelivery | null }> {
  const denied = await manageableInvitation(invitationId);
  if (denied) return { error: denied };
  return { error: null, delivery: await deliverInvitation(invitationId) };
}

export async function revokeInvitation(invitationId: string): Promise<{ error: string | null }> {
  const denied = await manageableInvitation(invitationId);
  if (denied) return { error: denied };
  const { error } = await supabaseServiceRole().from('tenant_invitation').delete().eq('id', invitationId);
  if (error) return { error: 'Could not revoke the invitation.' };
  revalidatePath('/staff');
  return { error: null };
}

const RegisterStaffSchema = z.object({
  campusId: z.string().uuid('Valid campus is required'),
  fullName: z.string().min(2, 'Full name must be at least 2 characters').max(200),
  fullNameUr: z.string().max(200).optional(),
  gender: z.enum(['male', 'female', 'other']),
  idDocumentType: z.enum(['cnic', 'passport']).default('cnic'),
  cnic: z.string().optional(),
  passportNo: z.string().optional(),
  dob: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Date of birth required (YYYY-MM-DD)'),
  doj: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Date of joining required (YYYY-MM-DD)'),
  contractType: z.enum(['permanent', 'contractual', 'visiting']).default('permanent'),
  mobile: z.string().min(10, 'Mobile number is required (e.g. 0300-1234567)').max(25),
  altMobile: z.string().max(25).optional(),
  address: z.string().max(500).optional(),
  emergencyContact: z.string().max(100).optional(),
  role: z.enum(CORE_STAFF_ROLES).default('subject_teacher'),
  departmentId: z.string().uuid().optional().or(z.literal('')),
  email: z.string().email('Invalid email address').optional().or(z.literal('')),
});

export async function registerStaffMember(formData: FormData): Promise<{
  error: string | null;
  data?: { staff_id: string; employee_code: string; full_name: string; invitation_id?: string | null };
  delivery?: InviteDelivery | null;
}> {
  const emailVal = formData.get('email');
  const deptVal = formData.get('departmentId');
  const parsed = RegisterStaffSchema.safeParse({
    campusId: formData.get('campusId'),
    fullName: formData.get('fullName'),
    fullNameUr: formData.get('fullNameUr') || undefined,
    gender: formData.get('gender'),
    idDocumentType: formData.get('idDocumentType') || 'cnic',
    cnic: formData.get('cnic') || undefined,
    passportNo: formData.get('passportNo') || undefined,
    dob: formData.get('dob'),
    doj: formData.get('doj'),
    contractType: formData.get('contractType') || 'permanent',
    mobile: formData.get('mobile'),
    altMobile: formData.get('altMobile') || undefined,
    address: formData.get('address') || undefined,
    emergencyContact: formData.get('emergencyContact') || undefined,
    role: formData.get('role') || 'subject_teacher',
    departmentId: deptVal && String(deptVal).trim() !== '' ? String(deptVal).trim() : undefined,
    email: emailVal && String(emailVal).trim() !== '' ? String(emailVal).trim() : undefined,
  });

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input' };
  }

  const supabase = await supabaseServer();
  const { data, error } = await (supabase.rpc as any)('register_staff_member', {
    p_campus_id: parsed.data.campusId,
    p_full_name: parsed.data.fullName.trim(),
    p_gender: parsed.data.gender,
    p_id_document_type: parsed.data.idDocumentType,
    p_cnic: parsed.data.cnic?.trim() || null,
    p_passport_no: parsed.data.passportNo?.trim() || null,
    p_full_name_ur: parsed.data.fullNameUr?.trim() || null,
    p_contract_type: parsed.data.contractType,
    p_dob: parsed.data.dob,
    p_doj: parsed.data.doj,
    p_mobile: parsed.data.mobile?.trim() || null,
    p_alt_mobile: parsed.data.altMobile?.trim() || null,
    p_address: parsed.data.address?.trim() || null,
    p_emergency_contact: parsed.data.emergencyContact?.trim() || null,
    p_role: parsed.data.role,
    p_email: parsed.data.email || null,
    p_department_id: parsed.data.departmentId || null,
  });

  if (error) {
    if (error.message.includes('CNIC_CONFLICT')) {
      return { error: error.details || 'A staff member with this CNIC already exists in the system.' };
    }
    if (error.message.includes('CNIC_REQUIRED')) {
      return { error: 'National ID Card (CNIC) is required.' };
    }
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'You do not have permission to register staff.' };
    }
    return { error: error.message || 'Failed to register staff member.' };
  }

  revalidatePath('/staff');
  revalidatePath('/staff/directory');
  revalidatePath('/staff/departments');
  const created = data as { staff_id: string; employee_code: string; full_name: string; invitation_id?: string | null };
  const delivery = created.invitation_id ? await deliverInvitation(created.invitation_id) : null;
  return { error: null, data: created, delivery };
}
