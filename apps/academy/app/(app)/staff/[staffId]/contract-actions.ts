'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { staffContractSchema } from '@/lib/validation';
import { parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  ex_staff_contract_no_overlap: 'A contract already starts on or after that date. Start the new contract after the current one began.',
  STAFF_NOT_FOUND: 'This staff member was not found.',
};

export async function addStaffContract(staffId: string, values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(staffContractSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_staff_contract', {
    p_staff_id: staffId,
    p_contract_type: p.data.contractType,
    p_start_date: p.data.startDate,
    p_gross_salary: p.data.grossSalaryPkr,
    p_notice_period_days: p.data.noticeDays,
    p_contracted_periods_per_week: p.data.periodsPerWeek,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath(`/staff/${staffId}`);
  return { error: null, message: 'Contract saved. The previous one ends the day before it starts.' };
}

export async function confirmProbation(staffId: string, contractId: string): Promise<ActionResult> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('confirm_probation', { p_contract_id: contractId });
  if (error) return { error: rpcError(error.message) };
  revalidatePath(`/staff/${staffId}`);
  return { error: null, message: 'Probation confirmed.' };
}

export async function linkStaffLogin(staffId: string, values: Record<string, string>): Promise<ActionResult> {
  const raw = values.userId ?? '';
  if (raw !== 'none' && !/^[0-9a-f-]{36}$/i.test(raw)) return { error: 'Choose a login.' };
  const userId = raw === 'none' ? null : raw;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('link_staff_user_account', { p_staff_id: staffId, p_user_id: userId });
  if (error) return { error: rpcError(error.message, { ...MESSAGES, USER_ALREADY_LINKED: 'That login is already linked to another staff member.', USER_NOT_FOUND: 'That login is not an active user of this school.' }) };
  revalidatePath(`/staff/${staffId}`);
  return { error: null, message: userId ? 'Login linked.' : 'Login unlinked.' };
}

export async function setStaffBankAccount(staffId: string, values: Record<string, string>): Promise<ActionResult> {
  const bankName = (values.bankName ?? '').trim();
  const accountTitle = (values.accountTitle ?? '').trim();
  const accountNo = (values.accountNo ?? '').trim();
  if (!bankName || !accountTitle || !accountNo) return { error: 'Enter the bank, the account title and the account number.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_staff_bank_account', {
    p_staff_id: staffId,
    p_bank_name: bankName,
    p_account_title: accountTitle,
    p_account_no: accountNo,
  });
  if (error)
    return {
      error: rpcError(error.message, {
        ...MESSAGES,
        ACCOUNT_NO_INVALID: 'Enter a Pakistani IBAN (PK + 22 characters) or an account number of 6 to 20 digits.',
        BANK_FIELDS_REQUIRED: 'Enter the bank and the account title.',
      }),
    };
  revalidatePath(`/staff/${staffId}`);
  return { error: null, message: 'Bank account saved. It goes on the payroll bank file from the next export.' };
}
