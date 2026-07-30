import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { GuardianForm } from './guardian-form';
import { GuardianList } from './guardian-list';
import { EnrolForm } from './enrol-form';
import { FeePlanView, type FeePlanLineRow } from './fee-plan-view';
import { ConcessionAwardView, type AwardRow } from './concession-award-view';
import { LedgerView, type LedgerEntryRow } from './ledger-view';
import { PaymentView, type PaymentRow } from './payment-view';

// supabase-js types every embedded to-one relation as a possible array —
// the FK is unique per enrolment/section row, so it's really ever 0 or 1.
function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function StudentDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();

  const { data: student } = await supabase
    .from('student')
    .select('id, name_en, name_ur, gr_number, dob, gender, campus_id, status')
    .eq('id', id)
    .maybeSingle();
  if (!student) notFound();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const [{ data: enrolment }, { data: sections }, { data: guardianLinks }, { data: appUser }] = await Promise.all([
    supabase
      .from('enrolment')
      .select('id, roll_no, class_section(name, class_level(name_en))')
      .eq('student_id', id)
      .eq('status', 'active')
      .maybeSingle(),
    supabase.from('class_section').select('id, name, class_level(name_en)').eq('campus_id', student.campus_id).eq('is_active', true),
    supabase
      .from('student_guardian')
      .select('guardian_id, relationship, is_primary, receives_billing, may_collect_child, guardian(name_en, phone_e164, cnic)')
      .eq('student_id', id)
      .is('to_date', null),
    supabase.from('app_user').select('app_role').eq('user_id', user!.id).single(),
  ]);

  let feePlanLines: FeePlanLineRow[] = [];
  if (enrolment) {
    const { data: plan } = await supabase.from('fee_plan').select('id').eq('enrolment_id', enrolment.id).maybeSingle();
    if (plan) {
      const { data: lineRows } = await supabase
        .from('fee_plan_line')
        .select(
          'id, amount_paisa, pending_amount_paisa, override_reason, override_status, frequency, effective_to, fee_head(name_en, code)'
        )
        .eq('plan_id', plan.id);
      feePlanLines = (lineRows ?? []).map((l) => ({
        id: l.id,
        headName: one(l.fee_head)?.name_en ?? 'Unknown',
        headCode: one(l.fee_head)?.code ?? 'unknown',
        amountPaisa: l.amount_paisa,
        pendingAmountPaisa: l.pending_amount_paisa,
        overrideReason: l.override_reason,
        overrideStatus: l.override_status,
        frequency: l.frequency,
        effectiveTo: l.effective_to,
      }));
    }
  }

  const role = appUser?.app_role;
  const canAdjust = role === 'super_admin' || role === 'owner' || role === 'accountant';
  const canApprove = role === 'super_admin' || role === 'owner' || role === 'principal';
  const canRequestAward =
    role === 'super_admin' || role === 'owner' || role === 'principal' || role === 'accountant' || role === 'admissions_officer';
  const canPostLedger = role === 'super_admin' || role === 'owner' || role === 'accountant';
  const canReverseLedger = role === 'super_admin' || role === 'owner';
  const canRecordPayment = role === 'super_admin' || role === 'owner' || role === 'accountant';

  const { data: schemes } = await supabase
    .from('concession_scheme')
    .select('id, code, name_en, calc_type')
    .eq('is_active', true)
    .order('code');

  let awards: AwardRow[] = [];
  if (enrolment) {
    const { data: awardRows } = await supabase
      .from('concession_award')
      .select(
        'id, calc_type, value, effective_from, effective_to, status, rejection_reason, concession_scheme(name_en, approver_role)'
      )
      .eq('enrolment_id', enrolment.id)
      .order('created_at', { ascending: false });
    awards = (awardRows ?? []).map((a) => {
      const scheme = one(a.concession_scheme);
      return {
        id: a.id,
        schemeName: scheme?.name_en ?? 'Unknown',
        calcType: a.calc_type,
        value: a.value,
        effectiveFrom: a.effective_from,
        effectiveTo: a.effective_to,
        status: a.status,
        rejectionReason: a.rejection_reason,
        canApprove: role === 'super_admin' || role === 'owner' || role === scheme?.approver_role,
      };
    });
  }

  let ledgerEntries: LedgerEntryRow[] = [];
  let balancePaisa = 0;
  if (enrolment) {
    const [{ data: ledgerRows }, { data: balance }] = await Promise.all([
      supabase
        .from('fee_ledger')
        .select('id, entry_type, amount_paisa, direction, value_date, reversal_of_id')
        .eq('enrolment_id', enrolment.id)
        .order('posted_at', { ascending: false }),
      supabase.rpc('student_balance', { p_enrolment_id: enrolment.id }),
    ]);
    const reversedIds = new Set((ledgerRows ?? []).map((r) => r.reversal_of_id).filter(Boolean));
    ledgerEntries = (ledgerRows ?? []).map((r) => ({
      id: r.id,
      entryType: r.entry_type,
      amountPaisa: r.amount_paisa,
      direction: r.direction,
      valueDate: r.value_date,
      reversalOfId: r.reversal_of_id,
      isReversed: reversedIds.has(r.id),
    }));
    balancePaisa = balance ?? 0;
  }

  let payments: PaymentRow[] = [];
  if (enrolment) {
    const { data: paymentRows } = await supabase
      .from('fee_payment')
      .select('id, amount_paisa, mode, value_date, reference_no')
      .eq('enrolment_id', enrolment.id)
      .order('received_at', { ascending: false });
    const paymentIds = (paymentRows ?? []).map((p) => p.id);
    const { data: allocationRows } =
      paymentIds.length > 0
        ? await supabase
            .from('fee_payment_allocation')
            .select('payment_id, amount_paisa, fee_challan(challan_no), fee_head(code)')
            .in('payment_id', paymentIds)
        : { data: [] };
    payments = (paymentRows ?? []).map((p) => ({
      id: p.id,
      amountPaisa: p.amount_paisa,
      mode: p.mode,
      valueDate: p.value_date,
      referenceNo: p.reference_no,
      allocations: (allocationRows ?? [])
        .filter((a) => a.payment_id === p.id)
        .map((a) => ({
          challanNo: one(a.fee_challan)?.challan_no ?? 'unknown',
          feeHeadCode: one(a.fee_head)?.code ?? 'unknown',
          amountPaisa: a.amount_paisa,
        })),
    }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">{student.name_en}</h1>
        <p className="text-sm text-muted-foreground">
          GR {student.gr_number} · {student.gender} · DOB {student.dob} · {student.status}
        </p>
      </div>

      <section className="space-y-2">
        <h2 className="text-lg font-medium">Enrolment</h2>
        {(() => {
          const section = enrolment ? one(enrolment.class_section) : null;
          const classLevel = section ? one(section.class_level) : null;
          return section && classLevel ? (
            <p data-testid="student-enrolment" className="text-sm">
              {classLevel.name_en} · Section {section.name} · Roll {enrolment!.roll_no ?? '—'}
            </p>
          ) : (
            <EnrolForm studentId={student.id} sections={sections ?? []} />
          );
        })()}
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-medium">Guardians</h2>
        <GuardianList links={guardianLinks ?? []} />
        <GuardianForm studentId={student.id} />
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-medium">Fees</h2>
        <FeePlanView studentId={student.id} lines={feePlanLines} canAdjust={canAdjust} canApprove={canApprove} />
      </section>

      {enrolment && (
        <section className="space-y-2">
          <h2 className="text-lg font-medium">Concession awards</h2>
          <ConcessionAwardView
            studentId={student.id}
            enrolmentId={enrolment.id}
            awards={awards}
            schemes={schemes ?? []}
            canRequest={canRequestAward}
          />
        </section>
      )}

      {enrolment && (
        <section className="space-y-2">
          <h2 className="text-lg font-medium">Payments</h2>
          <PaymentView studentId={student.id} enrolmentId={enrolment.id} payments={payments} canRecord={canRecordPayment} />
        </section>
      )}

      {enrolment && (
        <section className="space-y-2">
          <h2 className="text-lg font-medium">Ledger</h2>
          <LedgerView
            studentId={student.id}
            enrolmentId={enrolment.id}
            balancePaisa={balancePaisa}
            entries={ledgerEntries}
            canPost={canPostLedger}
            canReverse={canReverseLedger}
          />
        </section>
      )}
    </div>
  );
}
