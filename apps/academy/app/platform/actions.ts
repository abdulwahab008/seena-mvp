'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { provisionTenantSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';
import { deliverInvitation, type InviteDelivery } from '@/lib/staff-invite';

export type ProvisionState = { error: string | null; tenantId: string | null; delivery?: InviteDelivery | null };

export async function provisionSchool(_prev: ProvisionState, formData: FormData): Promise<ProvisionState> {
  const parsed = provisionTenantSchema.safeParse({
    slug: formData.get('slug'),
    legalName: formData.get('legalName'),
    ownerEmail: formData.get('ownerEmail'),
  });
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', tenantId: null };
  }

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('platform_provision_tenant', {
    p_slug: parsed.data.slug,
    p_legal_name: parsed.data.legalName,
    p_owner_email: parsed.data.ownerEmail,
  });
  if (error) {
    if (error.message.includes('TENANT_SLUG_TAKEN')) return { error: 'That school code is already in use.', tenantId: null };
    if (error.message.includes('TENANT_SLUG_INVALID')) return { error: 'That school code is not a valid format.', tenantId: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only platform admins can create schools.', tenantId: null };
    return { error: 'Could not create the school.', tenantId: null };
  }

  const { data: inviteId } = await supabase.rpc('platform_renew_owner_invite', { p_tenant_id: data });
  const delivery = inviteId ? await deliverInvitation(inviteId) : null;
  revalidatePath('/platform');
  return { error: null, tenantId: data, delivery };
}

const StatusSchema = z.object({
  tenantId: z.string().uuid(),
  status: z.enum(['active', 'suspended', 'closed']),
  reason: z.string().trim().min(1, 'Give a reason.').max(500),
});

export async function setSchoolStatus(input: z.input<typeof StatusSchema>): Promise<{ error: string | null }> {
  const parsed = StatusSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('platform_set_tenant_status', {
    p_tenant_id: parsed.data.tenantId,
    p_status: parsed.data.status,
    p_reason: parsed.data.reason,
  });
  if (error) {
    if (error.message.includes('TENANT_CLOSED')) return { error: 'A closed school cannot be reopened.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only platform admins can change a school’s status.' };
    return { error: 'Could not change the school’s status.' };
  }
  revalidatePath('/platform');
  return { error: null };
}

export async function resendOwnerInvite(tenantId: string): Promise<{ error: string | null; delivery: InviteDelivery | null }> {
  const supabase = await supabaseServer();
  const { data: inviteId, error } = await supabase.rpc('platform_renew_owner_invite', { p_tenant_id: tenantId });
  if (error) return { error: 'Only platform admins can resend invitations.', delivery: null };
  if (!inviteId) return { error: 'This school’s owner has already joined.', delivery: null };
  return { error: null, delivery: await deliverInvitation(inviteId) };
}

const RegistrationStatusSchema = z.object({ id: z.string().uuid(), status: z.enum(['new', 'contacted', 'onboarded', 'declined']) });

export async function setRegistrationStatus(input: z.input<typeof RegistrationStatusSchema>): Promise<{ error: string | null }> {
  const parsed = RegistrationStatusSchema.safeParse(input);
  if (!parsed.success) return { error: 'Invalid status.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('platform_set_registration_status', { p_id: parsed.data.id, p_status: parsed.data.status });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only platform admins can do this.' : 'Could not update the request.' };
  revalidatePath('/platform');
  return { error: null };
}
