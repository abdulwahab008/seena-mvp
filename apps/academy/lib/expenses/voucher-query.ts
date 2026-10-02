import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '../database.types';

/**
 * FR-L11's one read of the voucher desk and the approval queue.
 *
 * Both screens ask the same two questions — which vouchers, and what has
 * been decided about them — so they ask them in one place. v_expense_voucher
 * and v_expense_voucher_approval are both security_invoker, so RLS decides
 * what comes back and neither page re-implements the scope.
 */

type Db = SupabaseClient<Database>;

export type VoucherRow = Database['public']['Views']['v_expense_voucher']['Row'];
export type ApprovalRow = Database['public']['Views']['v_expense_voucher_approval']['Row'];
export type VoucherStatus = Database['public']['Enums']['expense_voucher_status'];

export const VOUCHER_STATUS_LABEL: Record<VoucherStatus, string> = {
  pending_approval: 'Awaiting approval',
  approved: 'Approved',
  rejected: 'Rejected',
  paid: 'Paid',
};

export const APPROVER_ROLE_LABEL: Record<string, string> = {
  vice_principal: 'Vice Principal',
  principal: 'Principal',
  owner: 'Owner',
  super_admin: 'Super Admin',
};

// Mirrors app.fn_expense_role_rank(). The database is the authority — this
// only decides what a screen offers, never what it permits.
const ROLE_RANK: Record<string, number> = {
  vice_principal: 1,
  principal: 2,
  owner: 3,
  super_admin: 4,
};

export function approverRank(role: string | null | undefined): number {
  return role ? (ROLE_RANK[role] ?? 0) : 0;
}

export function canDecide(role: string, requiredRole: string | null): boolean {
  if (!['super_admin', 'owner', 'principal', 'vice_principal'].includes(role)) return false;
  return approverRank(role) >= approverRank(requiredRole);
}

export function requiredApproverLabel(requiredRole: string | null): string {
  return requiredRole ? (APPROVER_ROLE_LABEL[requiredRole] ?? requiredRole) : 'Self-approval';
}

export type VoucherFilters = { campusId: string; status: VoucherStatus | '' };

export async function readVouchers(
  supabase: Db,
  filters: VoucherFilters,
): Promise<{ rows: VoucherRow[]; approvals: ApprovalRow[] }> {
  let query = supabase
    .from('v_expense_voucher')
    .select('*')
    .order('voucher_date', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(200);
  if (filters.campusId) query = query.eq('campus_id', filters.campusId);
  if (filters.status) query = query.eq('status', filters.status);

  const { data: rows } = await query;
  const voucherIds = (rows ?? []).map((r) => r.id).filter((id): id is string => id !== null);
  if (voucherIds.length === 0) return { rows: rows ?? [], approvals: [] };

  const { data: approvals } = await supabase
    .from('v_expense_voucher_approval')
    .select('*')
    .in('voucher_id', voucherIds)
    .order('decided_at', { ascending: true });

  return { rows: rows ?? [], approvals: approvals ?? [] };
}
