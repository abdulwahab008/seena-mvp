import { supabaseServer } from '@/lib/supabase/server';
import { readVouchers, type VoucherStatus } from '@/lib/expenses/voucher-query';
import { VoucherDesk } from './voucher-desk';

/**
 * FR-L11. The submission desk: raise a voucher with its bill, watch it move,
 * and pay it once whoever the amount requires has signed.
 *
 * The role gate mirrors submit_expense_voucher()'s own — a Class Teacher
 * cannot raise a voucher, and the database says so regardless of what this
 * page renders.
 */
const VOUCHER_ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'accountant'];

const STATUSES: VoucherStatus[] = ['pending_approval', 'approved', 'rejected', 'paid'];

type SearchParams = { campus?: string; status?: string };

export default async function ExpenseVouchersPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';

  if (!VOUCHER_ROLES.includes(role)) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Expense vouchers</h1>
        <p className="text-sm text-muted-foreground" data-testid="expense-vouchers-forbidden">
          Only an Accountant, Vice Principal, Principal, Owner or Super Admin can raise an expense voucher.
        </p>
      </div>
    );
  }

  const [{ data: campusRows }, { data: headRows }] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    supabase.from('expense_head').select('id, code, name_en, requires_approval').eq('is_active', true).order('code'),
  ]);
  const campuses = campusRows ?? [];

  const filters = {
    campusId: campuses.some((c) => c.id === params.campus) ? params.campus! : '',
    status: (STATUSES as string[]).includes(params.status ?? '') ? (params.status as VoucherStatus) : ('' as const),
  };

  const { rows, approvals } = await readVouchers(supabase, filters);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Expense vouchers</h1>
        <p className="text-sm text-muted-foreground">
          FR-L11 — a voucher above the campus self-approval limit goes to the approver its amount requires and cannot be paid
          until they sign. Two vouchers for the same payee, head and date on the same day are flagged as a possible split and
          both go up for approval.
        </p>
      </div>

      <VoucherDesk
        role={role}
        campuses={campuses}
        heads={headRows ?? []}
        filters={filters}
        rows={rows}
        approvals={approvals}
      />
    </div>
  );
}
