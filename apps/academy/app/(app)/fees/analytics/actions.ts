'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

export async function sendFeeSlips(campusId: string, month: string): Promise<{ error: string | null; queued?: number; noPhone?: number }> {
  const p = z.object({ campusId: z.string().uuid(), month: z.string().regex(/^\d{4}-\d{2}$/, 'Choose a month') }).safeParse({ campusId, month });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Choose a month.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('queue_fee_slip_messages', { p_campus_id: p.data.campusId, p_billing_period: `${p.data.month}-01` });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only the accountant, Principal or owner can send fee reminders.' : 'Something went wrong. Try again.' };
  const r = data as { queued: number; no_phone: number };
  return { error: null, queued: r.queued, noPhone: r.no_phone };
}
