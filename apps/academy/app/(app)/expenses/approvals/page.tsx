import { supabaseServer } from '@/lib/supabase/server';
import { readVouchers } from '@/lib/expenses/voucher-query';
import { ApprovalQueue } from './approval-queue';

/**
 * FR-L11 AC1. The Principal's (and Owner's) pending queue.
 *
 * The gate mirrors decide_expense_voucher()'s own role list. The queue shows
 * every voucher waiting at this user's campuses, including ones above their
 * own limit — a Principal should be able to see that a PKR 300,000 voucher
 * is sitting with the Owner — but the approve/reject controls only appear
 * where the database would actually accept the decision.
 */
const APPROVER_ROLES = ['super_admin', 'owner', 'principal', 'vice_principal'];

export default async function ExpenseApprovalsPage({
  searchParams,
}: {
  searchParams: Promise<{ campus?: string }>;
}) {
  const params = await searchParams;
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';

  if (!APPROVER_ROLES.includes(role)) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Vouchers awaiting approval</h1>
        <p className="text-sm text-muted-foreground" data-testid="expense-approvals-forbidden">
          Only a Vice Principal, Principal, Owner or Super Admin can approve an expense voucher.
        </p>
      </div>
    );
  }

  const { data: campusRows } = await supabase
    .from('campus')
    .select('id, code, name')
    .eq('status', 'active')
    .order('code');
  const campuses = campusRows ?? [];

  const filters = {
    campusId: campuses.some((c) => c.id === params.campus) ? params.campus! : '',
    status: 'pending_approval' as const,
  };

  const { rows, approvals } = await readVouchers(supabase, filters);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Vouchers awaiting approval</h1>
        <p className="text-sm text-muted-foreground">
          FR-L11 — nothing here has been paid, and nothing here can be until it is approved by the role its amount requires. A
          rejection needs a reason of at least 10 characters and is final: the voucher is locked and a correction means a new
          one.
        </p>
      </div>

      <ApprovalQueue role={role} campuses={campuses} filters={filters} rows={rows} approvals={approvals} />
    </div>
  );
}
