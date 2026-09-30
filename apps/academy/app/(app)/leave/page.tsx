import { supabaseServer } from '@/lib/supabase/server';
import { LeaveDashboard, type LeaveRosterRow, type LeavePolicy } from './leave-dashboard';
import { type LeaveType, type StaffOption } from './apply-leave-form';
import { type ApplicationRow } from './application-list';
import { type PendingRow } from './approval-queue';

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
    supabase
      .from('staff')
      .select('id, full_name, employee_code')
      .eq('user_id', user!.id)
      .maybeSingle(),
    supabase
      .from('app_user')
      .select('app_role, tenant_id')
      .eq('user_id', user!.id)
      .single(),
  ]);

  const isApprover = !!appUser && APPROVER_ROLES.includes(appUser.app_role);

  // Fetch active staff list for selection
  let staffList: StaffOption[] = [];
  const { data: rawStaffList } = await supabase
    .from('staff')
    .select('id, full_name, employee_code')
    .eq('employment_status', 'active')
    .order('full_name');
  staffList = rawStaffList ?? [];

  // Fetch leave types & balances
  let leaveTypes: LeaveType[] = [];
  let balances: Record<string, number> = {};
  let myApplications: ApplicationRow[] = [];

  const targetStaffId = staff?.id || (staffList.length > 0 && staffList[0] ? staffList[0].id : null);

  if (staff) {
    const [{ data: types }, { data: ledger }, { data: apps }] = await Promise.all([
      supabase.rpc('eligible_leave_types', { p_staff_id: staff.id }),
      supabase.from('leave_ledger').select('leave_type_id, days').eq('staff_id', staff.id),
      supabase
        .from('leave_application')
        .select(
          'id, from_date, to_date, is_half_day, working_days, status, reason, submitted_at, leave_type(code, name_en, is_paid)'
        )
        .eq('staff_id', staff.id)
        .order('submitted_at', { ascending: false }),
    ]);

    leaveTypes = (types ?? []).map((t) => ({ ...t, is_paid: t.is_paid ?? true }));
    balances = (ledger ?? []).reduce<Record<string, number>>((acc, row) => {
      acc[row.leave_type_id] = (acc[row.leave_type_id] ?? 0) + Number(row.days);
      return acc;
    }, {});
    myApplications = (apps ?? []).map((a) => ({ ...a, leave_type: one(a.leave_type) }));
  } else if (targetStaffId) {
    // For an administrative user without a linked staff record, prefill balances from the first staff member
    const [{ data: types }, { data: ledger }] = await Promise.all([
      supabase.rpc('eligible_leave_types', { p_staff_id: targetStaffId }),
      supabase.from('leave_ledger').select('leave_type_id, days').eq('staff_id', targetStaffId),
    ]);

    leaveTypes = (types ?? []).map((t) => ({ ...t, is_paid: t.is_paid ?? true }));
    balances = (ledger ?? []).reduce<Record<string, number>>((acc, row) => {
      acc[row.leave_type_id] = (acc[row.leave_type_id] ?? 0) + Number(row.days);
      return acc;
    }, {});
  }

  // Fetch pending applications for approver
  let pendingApplications: PendingRow[] = [];
  if (isApprover) {
    const { data } = await supabase
      .from('leave_application')
      .select(
        'id, from_date, to_date, is_half_day, working_days, reason, submitted_at, leave_type(name_en, is_paid), staff(full_name, employee_code)'
      )
      .eq('status', 'pending')
      .order('submitted_at', { ascending: true });
    pendingApplications = (data ?? []).map((p) => ({
      ...p,
      leave_type: one(p.leave_type),
      staff: one(p.staff),
    }));
  }

  // Fetch all applications for Roster
  let allApplications: LeaveRosterRow[] = [];
  if (isApprover) {
    const { data } = await supabase
      .from('leave_application')
      .select(
        'id, from_date, to_date, is_half_day, working_days, reason, status, submitted_at, leave_type(code, name_en, is_paid), staff(id, full_name, employee_code)'
      )
      .order('submitted_at', { ascending: false })
      .limit(100);
    allApplications = (data ?? []).map((r) => ({
      ...r,
      leave_type: one(r.leave_type),
      staff: one(r.staff),
    }));
  }

  // Fetch all system leave policies
  const { data: dbPolicies } = await supabase
    .from('leave_type')
    .select(
      'id, code, name_en, entitlement_days, accrual_method, is_paid, doc_required_after_days, eligible_genders, eligible_contract_types, is_active'
    )
    .order('is_paid', { ascending: false })
    .order('code');
  const policies: LeavePolicy[] = (dbPolicies ?? []).map((p) => ({
    ...p,
    entitlement_days: Number(p.entitlement_days),
    is_active: p.is_active ?? true,
  }));

  // KPI Calculations
  const todayStr = new Date().toISOString().slice(0, 10);
  const onLeaveToday = allApplications.filter(
    (app) => app.status === 'approved' && app.from_date <= todayStr && app.to_date >= todayStr
  ).length;

  const totalPaidQuota = policies
    .filter((p) => p.is_paid && p.is_active)
    .reduce((sum, p) => sum + p.entitlement_days, 0);

  return (
    <LeaveDashboard
      isApprover={isApprover}
      userRole={appUser?.app_role ?? 'staff'}
      staffId={staff?.id}
      staffList={staffList}
      leaveTypes={leaveTypes}
      balances={balances}
      myApplications={myApplications}
      pendingApplications={pendingApplications}
      allApplications={allApplications}
      policies={policies}
      metrics={{
        onLeaveToday,
        pendingApprovals: pendingApplications.length,
        totalActiveStaff: staffList.length,
        totalPaidQuota,
      }}
    />
  );
}
