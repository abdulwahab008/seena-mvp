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
