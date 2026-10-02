import type { supabaseServer } from '@/lib/supabase/server';

type Supabase = Awaited<ReturnType<typeof supabaseServer>>;

/**
 * FR-C03: a student placed in a section gets the next roll number of that section.
 *
 * fn_assign_next_roll_no() exists in the database, but nothing in the enrolment
 * paths called it, so every newly enrolled student showed "Roll —". Called after a
 * successful enrolment from the app (enrol from an offer, enrol into a section, quick
 * walk-in admission). It is best effort by design: the student is already enrolled and
 * the roll number can still be set or re-sequenced later, so a failure here is logged
 * and never turns a successful admission into an error.
 *
 * Pass the enrolment id when the enrolling function returned it, otherwise the
 * student id (the student's newest active enrolment without a roll number is used).
 */
export async function assignRollNumberAfterEnrolment(
  supabase: Supabase,
  target: { enrolmentId?: string | null; studentId?: string | null },
): Promise<void> {
  try {
    let enrolmentId = target.enrolmentId ?? null;
    if (!enrolmentId && target.studentId) {
      const { data } = await supabase
        .from('enrolment')
        .select('id')
        .eq('student_id', target.studentId)
        .eq('status', 'active')
        .is('roll_no', null)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      enrolmentId = data?.id ?? null;
    }
    if (!enrolmentId) return;
    const { error } = await supabase.rpc('fn_assign_next_roll_no', { p_enrolment_id: enrolmentId });
    if (error) console.error('[roll-number] could not assign a roll number after enrolment:', error.message);
  } catch (e) {
    console.error('[roll-number] could not assign a roll number after enrolment:', e);
  }
}
