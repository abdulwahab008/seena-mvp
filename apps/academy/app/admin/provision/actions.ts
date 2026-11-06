'use server';

import { z } from 'zod';
import { provisionTenantSchema } from '@/lib/validation';
import { env } from '@/lib/env';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { deliverInvitation, type InviteDelivery } from '@/lib/staff-invite';

const FormSchema = provisionTenantSchema.extend({ setupToken: z.string() });

export type ProvisionState = { error: string | null; tenantId: string | null; delivery?: InviteDelivery | null };

// FR-A01: Tenant provisioning. Callable only by whoever holds
// ADMIN_SETUP_TOKEN (see lib/env.ts for why this is a bootstrap stand-in for
// a real super_admin check) — everything else is enforced in the
// provision_tenant() SECURITY DEFINER function itself.
export async function provisionTenant(
  _prev: ProvisionState,
  formData: FormData,
): Promise<ProvisionState> {
  const parsed = FormSchema.safeParse({
    slug: formData.get('slug'),
    legalName: formData.get('legalName'),
    ownerEmail: formData.get('ownerEmail'),
    setupToken: formData.get('setupToken'),
  });
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', tenantId: null };
  }
  if (parsed.data.setupToken !== env().ADMIN_SETUP_TOKEN) {
    return { error: 'Invalid setup token.', tenantId: null };
  }

  const { data, error } = await supabaseServiceRole().rpc('provision_tenant', {
    p_slug: parsed.data.slug,
    p_legal_name: parsed.data.legalName,
    p_owner_email: parsed.data.ownerEmail,
  });

  if (error) {
    if (error.message.includes('TENANT_SLUG_TAKEN')) {
      return { error: 'That slug is already in use.', tenantId: null };
    }
    if (error.message.includes('TENANT_SLUG_INVALID')) {
      return { error: 'That slug is not a valid format.', tenantId: null };
    }
    return { error: 'Could not provision tenant.', tenantId: null };
  }

  // Audit: provisioning created the owner's invitation but never sent it. Send it now and hand
  // the operator the link either way.
  const { data: invite } = await supabaseServiceRole()
    .from('tenant_invitation')
    .select('id')
    .eq('tenant_id', data as string)
    .eq('app_role', 'owner')
    .is('accepted_at', null)
    .maybeSingle();
  const delivery = invite ? await deliverInvitation(invite.id) : null;
  return { error: null, tenantId: data as string, delivery };
}
