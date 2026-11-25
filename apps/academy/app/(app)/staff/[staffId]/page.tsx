import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, one } from '@/lib/hr/current-role';
import { PhotoUpload } from '@/components/photo-upload';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CorrectionForm, IssueForm, ReinstateForm } from './discipline-forms';
import { InitiateExitForm } from '../exits/exit-forms';
import { ActionForm } from '@/components/action-form';
import { ActionButton } from '@/components/spec-form';
import { CONTRACT_TYPE_LABEL } from '@/lib/validation';
import { formatDatePk, todayPk } from '@/lib/dates';
import { pkr } from '@/lib/rpc-action';
import { addStaffContract, confirmProbation, linkStaffLogin, setStaffBankAccount } from './contract-actions';

export const dynamic = 'force-dynamic';

const TYPE_LABEL: Record<string, string> = {
  warning: 'Warning',
  show_cause: 'Show-cause notice',
  inquiry: 'Inquiry',
  suspension: 'Suspension',
  termination: 'Termination (misconduct)',
  reinstatement: 'Reinstatement',
};

type DisciplinaryRow = {
  id: string;
  action_type: string;
  issued_on: string;
  issued_by_name: string | null;
  description: string;
  response_due_on: string | null;
  staff_response: string | null;
  responded_at: string | null;
  outcome: string | null;
  supersedes_id: string | null;
  created_at: string;
  superseded: boolean;
};

export default async function StaffProfilePage({ params }: { params: Promise<{ staffId: string }> }) {
  const { staffId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(staffId)) notFound();
  const supabase = await supabaseServer();
  const actor = await getCurrentActor();

  const { data: staff } = await supabase
    .from('staff')
    .select('id, user_id, employee_code, full_name, full_name_ur, employment_status, contract_type, doj, photo_path, designation:designation_id(name_en), department:department_id(name_en)')
    .eq('id', staffId)
    .maybeSingle();
  if (!staff) notFound();

  const { data: compliance } = await supabase.from('v_staff_compliance').select('compliance_status, expired_types, missing_types').eq('staff_id', staffId).maybeSingle();

  // FR-D15: the disciplinary record. HR and the Owner read it through the
  // restricted RPC; anyone else only ever gets the rows they issued themselves
  // (RLS), and the section is not rendered at all when there are none.
  const isReader = actor?.role === 'hr_manager' || actor?.role === 'owner';
  const canIssue = isReader || actor?.role === 'principal';
  let records: DisciplinaryRow[] = [];
  if (isReader) {
    const { data } = await supabase.rpc('list_staff_disciplinary', { p_staff_id: staffId });
    records = (data ?? []) as DisciplinaryRow[];
  } else {
    const { data } = await supabase
      .from('staff_disciplinary')
      .select('id, action_type, issued_on, description, response_due_on, staff_response, responded_at, outcome, supersedes_id, created_at')
      .eq('staff_id', staffId)
      .order('created_at');
    records = (data ?? []).map((r) => ({ ...r, issued_by_name: actor?.fullName ?? null, superseded: false }));
  }
  const showDiscipline = isReader || records.length > 0;
  const supersededIds = new Set(records.filter((r) => r.supersedes_id).map((r) => r.supersedes_id as string));

  // FR-D16: an exit in progress (or the chance to start one) for HR.
  const canHr = isHrWriter(actor?.role);
  const canBank = canHr || actor?.role === 'accountant';
  const { data: bank } = canBank
    ? await supabase.from('staff_bank_account').select('bank_name, account_title, account_no').eq('staff_id', staffId).maybeSingle()
    : { data: null };
  const { data: openExit } = canHr ? await supabase.from('staff_exit').select('id, status, exit_type, last_working_date').eq('staff_id', staffId).neq('status', 'completed').maybeSingle() : { data: null };

  const { data: contracts } = canHr
    ? await supabase
        .from('staff_contract')
        .select('id, contract_type, start_date, end_date, notice_period_days, contracted_periods_per_week, probation_confirmed_at, staff_contract_pay(gross_salary)')
        .eq('staff_id', staffId)
        .order('start_date', { ascending: false })
    : { data: null };
  const canLink = canHr;
  const [{ data: users }, { data: linkedStaff }] = canLink
    ? await Promise.all([
        supabase.from('app_user').select('user_id, full_name, app_role').eq('status', 'active').neq('app_role', 'parent').order('full_name'),
        supabase.from('staff').select('user_id').not('user_id', 'is', null),
      ])
    : [{ data: null }, { data: null }];
  const taken = new Set((linkedStaff ?? []).map((r) => r.user_id).filter((u) => u !== staff.user_id));
  const linkedUser = (users ?? []).find((u) => u.user_id === staff.user_id);
  const { data: photo } = staff.photo_path ? await supabase.storage.from('staff-photos').createSignedUrl(staff.photo_path, 3600) : { data: null };
  const designation = one(staff.designation)?.name_en;
  const department = one(staff.department)?.name_en;
  const complianceStatus = compliance?.compliance_status ?? null;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex items-center gap-4">
          <PhotoUpload kind="staff" id={staff.id} name={staff.full_name} url={photo?.signedUrl ?? null} canEdit={canHr} />
          <div>
          <h1 className="text-2xl font-semibold" data-testid="staff-name">
            {staff.full_name}
          </h1>
          <p className="text-sm text-muted-foreground">
            {staff.employee_code} · {designation ?? 'No designation'} · {department ?? 'No department'}
          </p>
          </div>
        </div>
        <Badge variant={staff.employment_status === 'active' ? 'success' : 'outline'}>{staff.employment_status.replace('_', ' ')}</Badge>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Employment</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-2 text-sm sm:grid-cols-3">
          <p>
            <span className="text-muted-foreground">Joined</span> {staff.doj}
          </p>
          <p>
            <span className="text-muted-foreground">Contract</span> {staff.contract_type}
          </p>
          <p>
            <span className="text-muted-foreground">Document compliance</span>{' '}
            {complianceStatus ? <Link href="/staff/compliance" className="underline">{complianceStatus.replace('_', '-')}</Link> : 'not available'}
          </p>
        </CardContent>
      </Card>

      {canLink && (
        <Card data-testid="login-card">
          <CardHeader>
            <CardTitle className="text-base">Login</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4 text-sm md:grid-cols-2">
            <p data-testid="linked-login">
              {staff.user_id ? `Signs in as ${linkedUser?.full_name ?? 'a user'}${linkedUser ? ` (${linkedUser.app_role.replaceAll('_', ' ')})` : ''}.` : 'Not linked to a login, so this person cannot see their own leave, payslips or timetable.'}
            </p>
            <ActionForm
              testId="link-login-form"
              submitLabel="Save"
              action={linkStaffLogin.bind(null, staff.id)}
              resetOnSuccess={false}
              fields={[
                {
                  name: 'userId',
                  label: 'Login',
                  type: 'select',
                  required: true,
                  defaultValue: staff.user_id ?? undefined,
                  options: [
                    ...(staff.user_id ? [{ value: 'none', label: 'No login (unlink)' }] : []),
                    ...(users ?? []).filter((u) => !taken.has(u.user_id)).map((u) => ({ value: u.user_id, label: `${u.full_name} (${u.app_role.replaceAll('_', ' ')})` })),
                  ],
                },
              ]}
            />
          </CardContent>
        </Card>
      )}

      {canHr && (
        <Card data-testid="contract-card">
          <CardHeader>
            <CardTitle className="text-base">Contract and salary</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            {(contracts ?? []).length === 0 ? (
              <p className="text-muted-foreground">No contract on file. Add one so the final settlement and security deposit know this person&apos;s salary.</p>
            ) : (
              <table className="w-full">
                <thead className="text-left text-muted-foreground">
                  <tr>
                    <th className="py-1 pr-3">Type</th>
                    <th className="pr-3">From</th>
                    <th className="pr-3">To</th>
                    <th className="pr-3 text-right">Gross / month</th>
                    <th className="pr-3">Notice</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {(contracts ?? []).map((c) => {
                    const gross = one(c.staff_contract_pay)?.gross_salary;
                    return (
                      <tr key={c.id} className="border-t" data-testid="contract-row">
                        <td className="py-1 pr-3">{CONTRACT_TYPE_LABEL[c.contract_type]}</td>
                        <td className="pr-3">{formatDatePk(c.start_date)}</td>
                        <td className="pr-3">{c.end_date ? formatDatePk(c.end_date) : 'Current'}</td>
                        <td className="pr-3 text-right tabular">{gross == null ? '-' : pkr(Math.round(Number(gross) * 100))}</td>
                        <td className="pr-3">{c.notice_period_days ? `${c.notice_period_days} days` : '-'}</td>
                        <td className="text-right">
                          {c.contract_type === 'probation' && !c.end_date && !c.probation_confirmed_at && (
                            <ActionButton label="Confirm probation" testId="confirm-probation" action={confirmProbation} args={[staffId, c.id]} />
                          )}
                          {c.probation_confirmed_at && <Badge variant="success">Confirmed</Badge>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
            <div className="max-w-xl">
              <h3 className="mb-2 font-medium">{(contracts ?? []).length === 0 ? 'Add the contract' : 'New contract or salary revision'}</h3>
              <ActionForm
                testId="contract-form"
                submitLabel="Save contract"
                action={addStaffContract.bind(null, staffId)}
                fields={[
                  { name: 'contractType', label: 'Type', type: 'select', required: true, options: Object.entries(CONTRACT_TYPE_LABEL).map(([value, label]) => ({ value, label })) },
                  { name: 'startDate', label: 'Starts on', type: 'date', required: true, defaultValue: todayPk() },
                  { name: 'grossSalaryPkr', label: 'Gross salary per month (PKR)', type: 'number', required: true },
                  { name: 'noticeDays', label: 'Notice period (days)', type: 'number' },
                  { name: 'periodsPerWeek', label: 'Periods per week (teachers)', type: 'number' },
                ]}
              />
            </div>
          </CardContent>
        </Card>
      )}

      {canBank && (
        <Card data-testid="bank-card">
          <CardHeader>
            <CardTitle className="text-base">Salary bank account</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p className="text-muted-foreground">
              {bank ? `${bank.bank_name} · ${bank.account_title} · ${bank.account_no}` : 'No bank account on file, so this person shows as MISSING on the payroll bank file.'}
            </p>
            <div className="max-w-xl">
              <ActionForm
                testId="bank-form"
                submitLabel={bank ? 'Update bank account' : 'Save bank account'}
                action={setStaffBankAccount.bind(null, staffId)}
                fields={[
                  { name: 'bankName', label: 'Bank', required: true, defaultValue: bank?.bank_name ?? '' },
                  { name: 'accountTitle', label: 'Account title', required: true, defaultValue: bank?.account_title ?? staff.full_name },
                  { name: 'accountNo', label: 'IBAN or account number', required: true, placeholder: 'PK36MEZN0000001234567890', defaultValue: bank?.account_no ?? '' },
                ]}
              />
            </div>
          </CardContent>
        </Card>
      )}

      {canHr && staff.employment_status !== 'exited' && (
        <Card data-testid="exit-card">
          <CardHeader>
            <CardTitle className="text-base">Leaving the school</CardTitle>
          </CardHeader>
          <CardContent>
            {openExit ? (
              <p className="text-sm">
                An exit is in progress ({openExit.exit_type.replace('_', ' ')}, last day {openExit.last_working_date}).{' '}
                <Link href={`/staff/exits/${openExit.id}`} className="underline" data-testid="open-exit-link">
                  Open the clearance checklist
                </Link>
              </p>
            ) : (
              <InitiateExitForm staffId={staffId} />
            )}
          </CardContent>
        </Card>
      )}

      {canIssue && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Raise a disciplinary matter</CardTitle>
          </CardHeader>
          <CardContent>
            <IssueForm staffId={staffId} canTerminate={isReader} />
          </CardContent>
        </Card>
      )}

      {showDiscipline && (
        <Card data-testid="disciplinary-section">
          <CardHeader>
            <CardTitle className="text-base">Disciplinary record</CardTitle>
            <p className="text-xs text-muted-foreground">Visible to HR, the Owner and the person who issued each entry. Entries cannot be edited or deleted.</p>
          </CardHeader>
          <CardContent className="space-y-3 text-sm" data-testid="disciplinary-list">
            {records.length === 0 && <p className="text-muted-foreground">No entries.</p>}
            {records.map((r) => {
              const head = !supersededIds.has(r.id);
              return (
                <div key={r.id} className="space-y-2 border-b pb-3" data-testid="disciplinary-row">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-medium">
                      {TYPE_LABEL[r.action_type] ?? r.action_type} · {r.issued_on}
                    </span>
                    <span className="flex items-center gap-2">
                      {r.supersedes_id && <Badge variant="outline">replaces an earlier entry</Badge>}
                      {!head && <Badge variant="outline">superseded</Badge>}
                      {r.action_type === 'show_cause' && head && !r.staff_response && r.response_due_on && <Badge variant="warning">response due {r.response_due_on}</Badge>}
                    </span>
                  </div>
                  <p>{r.description}</p>
                  {r.staff_response && (
                    <p className="text-muted-foreground">
                      Staff response ({r.responded_at ? new Date(r.responded_at).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' }) : ''}): {r.staff_response}
                    </p>
                  )}
                  {r.outcome && <p className="text-muted-foreground">Outcome: {r.outcome}</p>}
                  <p className="text-xs text-muted-foreground">Recorded {new Date(r.created_at).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}{r.issued_by_name ? ` by ${r.issued_by_name}` : ''}</p>
                  {isReader && head && r.action_type !== 'reinstatement' && (
                    <div className="flex flex-wrap items-start gap-3">
                      <CorrectionForm staffId={staffId} recordId={r.id} isShowCause={r.action_type === 'show_cause'} isSuspension={r.action_type === 'suspension'} />
                      {r.action_type === 'suspension' && <ReinstateForm staffId={staffId} recordId={r.id} />}
                    </div>
                  )}
                </div>
              );
            })}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
