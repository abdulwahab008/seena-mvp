'use server';

import { createHash, randomUUID } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { parseSettlement } from '@/lib/payments/settlement-parser';
import { unsettledDaysSchema, type UnsettledDaysInput } from '@/lib/validation';

const MAX_BYTES = 5 * 1024 * 1024;
const CHUNK = 500;
const GATEWAYS = z.enum(['jazzcash', 'easypaisa', 'onelink']);
const countsSchema = z.object({ row_count: z.number(), parsed: z.number(), failed: z.number() });
const reconcileSchema = z.object({ matched: z.number(), unmatched: z.number(), exceptions: z.number(), commission_paisa: z.number() });

export type SettlementUploadResult = { error: string } | { error: null; rows: number; matched: number; exceptions: number; commissionPaisa: number };

export async function uploadGatewaySettlement(formData: FormData): Promise<SettlementUploadResult> {
  const file = formData.get('file');
  const gateway = GATEWAYS.safeParse(formData.get('gateway'));
  if (!(file instanceof File) || file.size === 0 || !gateway.success) return { error: 'Choose a gateway and a CSV file.' };
  if (file.size > MAX_BYTES) return { error: 'The file is larger than 5 MB.' };

  const text = await file.text();
  const parsed = parseSettlement(text);
  if (parsed.fatal) return { error: parsed.fatal };

  const supabase = await supabaseServer();
  const sha = createHash('sha256').update(text, 'utf8').digest('hex');
  const storagePath = `gateway/${randomUUID()}.csv`;
  const { data: importId, error: startError } = await supabase.rpc('start_gateway_settlement_import', {
    p_gateway: gateway.data,
    p_file_sha256: sha,
    p_file_name: file.name.slice(0, 200),
    p_storage_path: storagePath,
  });
  if (startError || !importId) {
    if (startError?.message.startsWith('duplicate file')) return { error: startError.message };
    if (startError?.message.includes('FORBIDDEN')) return { error: 'You do not have permission to import settlement files.' };
    return { error: 'Could not start the import.' };
  }

  await supabaseServiceRole().storage.from('bank-statements').upload(storagePath, new Blob([text], { type: 'text/csv' }), { contentType: 'text/csv' });

  let rows = 0;
  for (let i = 0; i === 0 || i < parsed.lines.length; i += CHUNK) {
    const slice = parsed.lines.slice(i, i + CHUNK);
    const { data, error } = await supabase.rpc('add_gateway_settlement_lines', { p_import_id: importId, p_lines: slice, p_complete: i + CHUNK >= parsed.lines.length });
    if (error) return { error: 'Could not store the parsed rows.' };
    rows = countsSchema.parse(data).row_count;
    if (parsed.lines.length === 0) break;
  }

  const { data: result, error: reconcileError } = await supabase.rpc('reconcile_gateway_settlement', { p_import_id: importId });
  if (reconcileError) return { error: 'The file was stored but reconciliation failed. Try again from the imports list.' };
  const r = reconcileSchema.parse(result);
  revalidatePath('/fees/gateway-settlements');
  return { error: null, rows, matched: r.matched, exceptions: r.unmatched + r.exceptions, commissionPaisa: r.commission_paisa };
}

export async function setUnsettledDays(input: UnsettledDaysInput): Promise<{ error: string | null }> {
  const p = unsettledDaysSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_unsettled_after_days', { p_days: p.data.days });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You do not have permission to change this.' : 'Could not save.' };
  revalidatePath('/fees/gateway-settlements');
  return { error: null };
}
