import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, one } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CorrectionForm, IssueForm, ReinstateForm } from './discipline-forms';
import { InitiateExitForm } from '../exits/exit-forms';

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
    .select('id, employee_code, full_name, full_name_ur, employment_status, contract_type, doj, designation:designation_id(name_en), department:department_id(name_en)')
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
  const { data: openExit } = canHr ? await supabase.from('staff_exit').select('id, status, exit_type, last_working_date').eq('staff_id', staffId).neq('status', 'completed').maybeSingle() : { data: null };

  const designation = one(staff.designation)?.name_en;
  const department = one(staff.department)?.name_en;
  const complianceStatus = compliance?.compliance_status ?? null;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold" data-testid="staff-name">
            {staff.full_name}
          </h1>
          <p className="text-sm text-muted-foreground">
            {staff.employee_code} · {designation ?? 'No designation'} · {department ?? 'No department'}
          </p>
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
