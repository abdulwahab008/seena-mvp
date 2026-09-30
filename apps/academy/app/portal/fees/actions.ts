'use server';

import { headers } from 'next/headers';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { buildCheckout, GATEWAYS, type Checkout } from '@/lib/payments/gateways';

const inputSchema = z.object({ challanId: z.string().uuid(), gateway: z.enum(GATEWAYS) });
const intentSchema = z.object({
  intent_id: z.string().uuid(),
  gateway: z.enum(GATEWAYS),
  gateway_ref: z.string(),
  amount_paisa: z.number().int().positive(),
  expires_at: z.string(),
});

export type InitiatePaymentResult =
  | { error: string }
  | { error: null; checkout: Checkout; amountPaisa: number; expiresAt: string };

function mapError(message: string): string {
  if (message.includes('CHALLAN_ALREADY_SETTLED')) return 'This challan is already settled.';
  if (message.includes('GATEWAY_NOT_CONFIGURED')) return 'This payment method is not available at your school yet.';
  if (message.includes('FORBIDDEN')) return 'You cannot pay this challan.';
  return 'Could not start the payment. Please try again.';
}

// Signing happens here, on the server, with the secret read from the server
// environment by name — it never reaches the client bundle or the database.
export async function initiatePayment(input: z.input<typeof inputSchema>): Promise<InitiatePaymentResult> {
  const parsed = inputSchema.safeParse(input);
  if (!parsed.success) return { error: 'Invalid request.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('create_payment_intent', { p_challan_id: parsed.data.challanId, p_gateway: parsed.data.gateway });
  if (error) return { error: mapError(error.message) };
  const intent = intentSchema.safeParse(data);
  if (!intent.success) return { error: 'Unexpected response from the server.' };

  const admin = supabaseServiceRole();
  const { data: row } = await admin.from('payment_intent').select('tenant_id').eq('id', intent.data.intent_id).single();
  const { data: cfg } = await admin
    .from('payment_gateway_config')
    .select('merchant_id, secret_ref')
    .eq('tenant_id', row?.tenant_id ?? '')
    .eq('gateway', parsed.data.gateway)
    .maybeSingle();
  const secret = cfg ? process.env[cfg.secret_ref] : undefined;
  // A 1LINK voucher is just the challan number — it needs no signing secret.
  if (!cfg || (parsed.data.gateway !== 'onelink' && !secret)) return { error: 'This payment method is not available right now.' };

  const origin = process.env.NEXT_PUBLIC_SITE_URL ?? `https://${(await headers()).get('host') ?? 'localhost'}`;
  const checkout = buildCheckout({
    gateway: parsed.data.gateway,
    baseUrl: process.env[`PAYMENT_CHECKOUT_URL_${parsed.data.gateway.toUpperCase()}`],
    merchantId: cfg.merchant_id,
    secret: secret ?? '',
    intent: intent.data,
    returnUrl: `${origin}/portal/fees`,
  });
  if (!checkout) return { error: 'This payment method is not available right now.' };

  return { error: null, checkout, amountPaisa: intent.data.amount_paisa, expiresAt: intent.data.expires_at };
}
