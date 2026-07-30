'use server';

import { z } from 'zod';
import { provisionTenantSchema } from '@/lib/validation';
import { env } from '@/lib/env';
import { supabaseServiceRole } from '@/lib/supabase/server';

const FormSchema = provisionTenantSchema.extend({ setupToken: z.string() });

export type ProvisionState = { error: string | null; tenantId: string | null };

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

  return { error: null, tenantId: data as string };
}
