'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type FlagActionState = { error: string | null };

function rpcMessage(message: string): string {
  if (message.includes('FORBIDDEN')) return 'Only a Super Admin can change a tenant’s modules.';
  if (message.includes('FEATURE_UNKNOWN')) return 'That feature is not in the catalogue.';
  if (message.includes('PLAN_UNKNOWN')) return 'That plan does not exist.';
  if (message.includes('TENANT_NOT_FOUND')) return 'That school does not exist.';
  return 'Could not change the module.';
}

export async function setFeature(_prev: FlagActionState, formData: FormData): Promise<FlagActionState> {
  const supabase = await supabaseServer();
  const enabled = String(formData.get('enabled') ?? '');
  const { error } = await supabase.rpc('set_tenant_feature', {
    p_tenant_id: String(formData.get('tenantId') ?? ''),
    p_code: String(formData.get('code') ?? ''),
    // '' means "clear the override" — back to the plan default. It never
    // touches the module's data.
    p_enabled: enabled === '' ? undefined : enabled === 'true',
  });
  if (error) return { error: rpcMessage(error.message) };
  revalidatePath('/feature-flags');
  revalidatePath('/', 'layout');
  return { error: null };
}

export async function setPlan(_prev: FlagActionState, formData: FormData): Promise<FlagActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_tenant_plan', {
    p_tenant_id: String(formData.get('tenantId') ?? ''),
    p_plan_code: String(formData.get('planCode') ?? ''),
  });
  if (error) return { error: rpcMessage(error.message) };
  revalidatePath('/feature-flags');
  revalidatePath('/', 'layout');
  return { error: null };
}
