'use server';

import { createHash, randomUUID } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { parseStatement, type MappingProfile } from '@/lib/bank/parse-statement';
import { bankMappingProfileSchema, type BankMappingProfileInput } from '@/lib/validation';

const MAX_BYTES = 5 * 1024 * 1024;
const CHUNK = 500;

const profileRowSchema = z.object({
  column_map: z.object({
    txn_date: z.string(),
    challan_ref: z.string(),
    bank_ref: z.string(),
    amount: z.string().optional(),
    debit: z.string().optional(),
    credit: z.string().optional(),
  }),
  date_format: z.enum(['DD/MM/YYYY', 'DD-MM-YYYY', 'YYYY-MM-DD', 'DD-Mon-YYYY']),
  amount_sign_rule: z.enum(['credit_positive', 'separate_columns', 'absolute']),
  format: z.string(),
});

export type UploadResult = { error: string } | { error: null; importId: string; rows: number; parsed: number; failed: number };

export async function uploadBankStatement(formData: FormData): Promise<UploadResult> {
  const file = formData.get('file');
  const accountId = z.string().uuid().safeParse(formData.get('bankAccountId'));
  if (!(file instanceof File) || file.size === 0 || !accountId.success) return { error: 'Choose a bank account and a CSV file.' };
  if (file.size > MAX_BYTES) return { error: 'The file is larger than 5 MB.' };

  const supabase = await supabaseServer();
  const { data: account } = await supabase.from('campus_bank_account').select('mapping_profile_id').eq('id', accountId.data).maybeSingle();
  if (!account?.mapping_profile_id) return { error: 'This bank account has no mapping profile yet. Create one first.' };
  const { data: profileRow } = await supabase.from('bank_mapping_profile').select('*').eq('id', account.mapping_profile_id).maybeSingle();
  const profileParsed = profileRowSchema.safeParse(profileRow);
  if (!profileParsed.success) return { error: 'The mapping profile is invalid.' };
  if (profileParsed.data.format !== 'csv') return { error: 'Only CSV statements are supported. Export the statement as CSV.' };

  const text = await file.text();
  const profile: MappingProfile = {
    columnMap: profileParsed.data.column_map,
    dateFormat: profileParsed.data.date_format,
    amountSignRule: profileParsed.data.amount_sign_rule,
  };
  const parsed = parseStatement(text, profile);
  if (parsed.fatal) return { error: parsed.fatal };

  const sha = createHash('sha256').update(text, 'utf8').digest('hex');
  const storagePath = `${accountId.data}/${randomUUID()}.csv`;
  const { data: importId, error: startError } = await supabase.rpc('start_bank_statement_import', {
    p_bank_account_id: accountId.data,
    p_file_sha256: sha,
    p_file_name: file.name.slice(0, 200),
    p_storage_path: storagePath,
  });
  if (startError || !importId) {
    if (startError?.message.startsWith('duplicate file')) return { error: startError.message };
    return { error: 'Could not start the import.' };
  }

  await supabaseServiceRole().storage.from('bank-statements').upload(storagePath, new Blob([text], { type: 'text/csv' }), { contentType: 'text/csv' });

  let counts = { row_count: 0, parsed: 0, failed: 0 };
  for (let i = 0; i < parsed.lines.length || i === 0; i += CHUNK) {
    const slice = parsed.lines.slice(i, i + CHUNK);
    const { data, error } = await supabase.rpc('add_bank_statement_lines', {
      p_import_id: importId,
      p_lines: slice,
      p_complete: i + CHUNK >= parsed.lines.length,
    });
    if (error) return { error: 'Could not store the parsed rows.' };
    counts = z.object({ row_count: z.number(), parsed: z.number(), failed: z.number() }).parse(data);
    if (parsed.lines.length === 0) break;
  }

  revalidatePath('/fees/bank-statements');
  return { error: null, importId, rows: counts.row_count, parsed: counts.parsed, failed: counts.failed };
}

export async function saveMappingProfile(input: BankMappingProfileInput): Promise<{ error: string | null }> {
  const parsed = bankMappingProfileSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid profile.' };
  const v = parsed.data;

  const supabase = await supabaseServer();
  const { data: profileId, error } = await supabase.rpc('create_bank_mapping_profile', {
    p_name: v.name,
    p_format: 'csv',
    p_column_map:
      v.amountSignRule === 'separate_columns'
        ? { txn_date: v.txnDate, challan_ref: v.challanRef, bank_ref: v.bankRef, debit: v.debit, credit: v.credit }
        : { txn_date: v.txnDate, challan_ref: v.challanRef, bank_ref: v.bankRef, amount: v.amount },
    p_date_format: v.dateFormat,
    p_amount_sign_rule: v.amountSignRule,
  });
  if (error || !profileId) return { error: error?.message.includes('duplicate') ? 'A profile with that name exists.' : 'Could not save the profile.' };

  const { error: assignError } = await supabase.rpc('assign_bank_mapping_profile', { p_bank_account_id: v.bankAccountId, p_profile_id: profileId });
  if (assignError) return { error: 'Profile saved, but it could not be assigned to the account.' };

  revalidatePath('/fees/bank-statements');
  return { error: null };
}
