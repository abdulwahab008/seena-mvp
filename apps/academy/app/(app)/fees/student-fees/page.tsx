import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { hasFeeAccess } from '@/lib/auth/fee-access';
import { pickActiveCampus, pickSessionForCampus } from '@/lib/campus-context';
import { StudentFeesDesk, type StudentFeeRow } from './student-fees-desk';

export const dynamic = 'force-dynamic';

const select = 'h-9 rounded-md border bg-background px-2 text-sm';

export default async function StudentFeesPage({ searchParams }: { searchParams: Promise<{ cls?: string; head?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !hasFeeAccess(actor.role)) notFound();
  const f = await searchParams;
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: sessions }, { data: classLevels }, { data: feeHeads }] = await Promise.all([
    supabase.from('campus').select('id').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id, is_current, campus_id').eq('is_current', true).order('starts_on', { ascending: false }),
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('fee_head').select('id, code, name_en').eq('is_active', true).order('code'),
  ]);
  const campus = await pickActiveCampus(campuses);
  const session = pickSessionForCampus(sessions, campus?.id);
  const cls = classLevels?.find((c) => c.id === f.cls)?.id;
  const head = feeHeads?.find((h) => h.id === f.head)?.id ?? feeHeads?.find((h) => h.code === 'TUITION')?.id;

  let rows: StudentFeeRow[] = [];
  if (campus && session && cls && head) {
    const { data } = await supabase
      .from('fee_plan_line')
      .select(
        'id, amount_paisa, pending_amount_paisa, override_status, override_reason, fee_plan!inner(campus_id, session_id, enrolment!inner(status, class_level_id, roll_no, section:section_id(name), student!inner(id, name_en, gr_number)))'
      )
      .eq('fee_head_id', head)
      .is('effective_to', null)
      .eq('fee_plan.campus_id', campus.id)
      .eq('fee_plan.session_id', session.id)
      .eq('fee_plan.enrolment.status', 'active')
      .eq('fee_plan.enrolment.class_level_id', cls);
    rows = (data ?? [])
      .map((l) => {
        const enrolment = one(one(l.fee_plan)?.enrolment ?? null);
        const student = one(enrolment?.student ?? null);
        return {
          lineId: l.id,
          studentId: student?.id ?? '',
          name: student?.name_en ?? 'Unknown',
          grNumber: student?.gr_number ?? '',
          section: one(enrolment?.section ?? null)?.name ?? '',
          rollNo: enrolment?.roll_no ?? null,
          amountPaisa: l.amount_paisa,
          pendingAmountPaisa: l.pending_amount_paisa,
          pending: l.override_status === 'pending_approval',
          reason: l.override_reason,
        };
      })
      .sort((a, b) => a.section.localeCompare(b.section) || (a.rollNo ?? 9999) - (b.rollNo ?? 9999) || a.name.localeCompare(b.name));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Student fees</h1>
        <p className="text-sm text-muted-foreground">
          Change one fee for many students at once, e.g. a lower tuition fee for staff children. Changes apply to challans generated after
          approval.
        </p>
      </div>
      <form method="get" className="flex flex-wrap items-end gap-3">
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Class</span>
          <select name="cls" defaultValue={cls ?? ''} className={select} aria-label="Class">
            <option value="" disabled>
              Select a class
            </option>
            {(classLevels ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name_en}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Fee head</span>
          <select name="head" defaultValue={head ?? ''} className={select} aria-label="Fee head">
            {(feeHeads ?? []).map((h) => (
              <option key={h.id} value={h.id}>
                {h.name_en}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground">
          Show students
        </button>
      </form>
      {!campus || !session ? (
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      ) : !cls ? (
        <p className="text-sm text-muted-foreground">Choose a class to see its students and their fee.</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No student in this class has this fee yet. Fee plans are built when the fee structure is published.
        </p>
      ) : (
        <StudentFeesDesk
          key={`${cls}:${head}`}
          rows={rows}
          canApprove={['super_admin', 'owner', 'principal'].includes(actor.role)}
          canPropose={['super_admin', 'owner', 'accountant'].includes(actor.role)}
          canApproveNow={['super_admin', 'owner'].includes(actor.role)}
        />
      )}
    </div>
  );
}
