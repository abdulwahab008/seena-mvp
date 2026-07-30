import { supabaseServer } from '@/lib/supabase/server';
import { ApplyLeaveForm, type LeaveType } from './apply-leave-form';
import { ApplicationList, type ApplicationRow } from './application-list';
import { ApprovalQueue, type PendingRow } from './approval-queue';

const APPROVER_ROLES = ['super_admin', 'owner', 'principal', 'hr_manager'];

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function LeavePage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const [{ data: staff }, { data: appUser }] = await Promise.all([
    supabase.from('staff').select('id').eq('user_id', user!.id).maybeSingle(),
    supabase.from('app_user').select('app_role').eq('user_id', user!.id).single(),
  ]);
  const isApprover = !!appUser && APPROVER_ROLES.includes(appUser.app_role);

  let leaveTypes: LeaveType[] = [];
  let balances: Record<string, number> = {};
  let applications: ApplicationRow[] = [];

  if (staff) {
    const [{ data: types }, { data: ledger }, { data: apps }] = await Promise.all([
      supabase.rpc('eligible_leave_types', { p_staff_id: staff.id }),
      supabase.from('leave_ledger').select('leave_type_id, days').eq('staff_id', staff.id),
      supabase
        .from('leave_application')
        .select('id, from_date, to_date, is_half_day, working_days, status, reason, submitted_at, leave_type(code, name_en)')
        .eq('staff_id', staff.id)
        .order('submitted_at', { ascending: false }),
    ]);

    leaveTypes = types ?? [];
    balances = (ledger ?? []).reduce<Record<string, number>>((acc, row) => {
      acc[row.leave_type_id] = (acc[row.leave_type_id] ?? 0) + Number(row.days);
      return acc;
    }, {});
    applications = (apps ?? []).map((a) => ({ ...a, leave_type: one(a.leave_type) }));
  }

  let pending: PendingRow[] = [];
  if (isApprover) {
    const { data } = await supabase
      .from('leave_application')
      .select('id, from_date, to_date, is_half_day, working_days, reason, submitted_at, leave_type(name_en), staff(full_name)')
      .eq('status', 'pending')
      .order('submitted_at', { ascending: true });
    pending = (data ?? []).map((p) => ({ ...p, leave_type: one(p.leave_type), staff: one(p.staff) }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Leave</h1>
        <p className="text-sm text-muted-foreground">
          FR-D10/D11/D12 — apply for leave, track balances, and decide pending requests.
        </p>
      </div>
      {staff ? (
        <>
          <ApplyLeaveForm staffId={staff.id} leaveTypes={leaveTypes} balances={balances} />
          <ApplicationList applications={applications} />
        </>
      ) : (
        <p className="text-sm text-muted-foreground">Your account isn&apos;t linked to a staff record yet.</p>
      )}
      {isApprover && <ApprovalQueue applications={pending} />}
    </div>
  );
}
