'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { paymentGatewayConfigSchema, type PaymentGatewayConfigInput } from '@/lib/validation';

export async function saveGatewayConfig(input: PaymentGatewayConfigInput): Promise<{ error: string | null }> {
  const parsed = paymentGatewayConfigSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('upsert_payment_gateway_config', {
    p_gateway: parsed.data.gateway,
    p_merchant_id: parsed.data.merchantId,
    p_secret_ref: parsed.data.secretRef,
    p_is_live: parsed.data.isLive,
    p_is_enabled: parsed.data.isEnabled,
  });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only the owner can change payment gateways.' : 'Could not save the gateway.' };

  revalidatePath('/fees/gateways');
  return { error: null };
}
