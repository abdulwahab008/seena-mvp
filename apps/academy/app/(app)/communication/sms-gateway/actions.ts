'use server';

import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { HttpSmsTransport, formatPkMobile, type HttpSmsConfig } from '@/lib/comm/http-sms';
import { getCurrentActor } from '@/lib/hr/current-role';

const param = z.string().trim().regex(/^[A-Za-z0-9_.-]{1,40}$/, 'Letters, numbers, _ . - only');
const schema = z.object({
  url: z.string().trim().url().startsWith('https://', 'Use an https:// URL'),
  method: z.enum(['GET', 'POST']),
  keyParam: param,
  senderParam: param,
  toParam: param,
  textParam: param,
  successMatch: z.string().trim().max(40).optional(),
  numberFormat: z.enum(['intl', 'local']),
  senderId: z.string().trim().min(1, 'Enter the sender mask').max(20),
  apiKey: z.string().max(500).optional(),
});

export async function saveGateway(input: unknown): Promise<{ error: string | null }> {
  const p = schema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const { senderId, apiKey, ...config } = p.data;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_sms_gateway', { p_sender_id: senderId, p_config: config, p_api_key: apiKey || undefined });
  if (error) {
    if (error.message.includes('API_KEY_REQUIRED')) return { error: 'Enter the API key.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only the owner can change the SMS gateway.' };
    return { error: 'Could not save the gateway.' };
  }
  return { error: null };
}

export async function sendTestSms(to: string): Promise<{ error: string | null }> {
  if (!formatPkMobile(to)) return { error: 'Enter a Pakistani mobile number.' };
  const actor = await getCurrentActor();
  if (!actor || !['super_admin', 'owner'].includes(actor.role)) return { error: 'Only the owner can send a test.' };
  const { data } = await supabaseServiceRole().rpc('sms_gateway_for_dispatch', { p_tenant_id: actor.tenantId }).maybeSingle();
  if (!data) return { error: 'Save the gateway first.' };
  const result = await new HttpSmsTransport(data.config as HttpSmsConfig, data.api_key, data.sender_id ?? '').send({
    deliveryId: 'test-sms', channel: 'sms', languageCode: 'en', toMsisdn: to, toEmail: null, title: '', body: 'Test message from Seena Academy. Your SMS gateway works.', variables: [], templateName: null,
  });
  return result.ok ? { error: null } : { error: `The gateway said: ${result.errorText}` };
}
