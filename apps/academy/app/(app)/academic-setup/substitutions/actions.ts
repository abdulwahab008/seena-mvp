'use server';

import { revalidatePath } from 'next/cache';
import { assignSubstitutionSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

// timetable_substitution has three separate FKs to app_user
// (absent_staff_id, substitute_staff_id, created_by) — PostgREST's embed
// syntax can't reliably disambiguate which one a nested select means (the
// generated types surface this as SelectQueryError even with a column-name
// hint), so names are resolved with a plain lookup instead, the same way
// admissions/interviews/page.tsx already resolves panel_user_id.
async function resolveFullNames(supabase: Awaited<ReturnType<typeof supabaseServer>>, userIds: string[]): Promise<Map<string, string>> {
  const ids = Array.from(new Set(userIds));
  if (ids.length === 0) return new Map();
  const { data } = await supabase.from('app_user').select('user_id, full_name').in('user_id', ids);
  return new Map((data ?? []).map((u) => [u.user_id, u.full_name]));
}

export type AbsentTeacher = { staffUserId: string; fullName: string; status: string };

// FR-D13: the entry point into "who needs covering today" — teachers
// Module D's own daily attendance (FR-D07) or leave approval (FR-D11/D12)
// already marked absent/on_leave for this date.
export async function loadAbsentTeachers(campusId: string, date: string): Promise<{ error: string | null; teachers: AbsentTeacher[] }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase
    .from('staff_attendance')
    .select('status, staff:staff_id(user_id, full_name)')
    .eq('campus_id', campusId)
    .eq('att_date', date)
    .in('status', ['absent', 'on_leave']);
  if (error) return { error: "Could not load today's absences.", teachers: [] };

  const teachers: AbsentTeacher[] = [];
  for (const r of data ?? []) {
    const staff = one(r.staff);
    if (staff?.user_id) teachers.push({ staffUserId: staff.user_id, fullName: staff.full_name, status: r.status });
  }

  // FR-D15: a teacher on suspension is unavailable exactly like an absent one,
  // so their periods must be coverable from the same screen (the call carries
  // no disciplinary detail, only that they are suspended).
  const { data: suspended } = await supabase.rpc('get_suspended_teachers', { p_campus_id: campusId, p_date: date });
  for (const s of suspended ?? []) {
    if (!teachers.some((t) => t.staffUserId === s.staff_user_id)) teachers.push({ staffUserId: s.staff_user_id, fullName: s.full_name, status: 'suspended' });
  }

  return { error: null, teachers };
}

export type PeriodRow = {
  slotId: string;
  periodNo: number;
  sectionName: string;
  subjectCode: string;
  substitutionStatus: 'active' | 'review' | null;
  substituteName: string | null;
};

// AC1: every period the absent teacher owns that weekday, with today's
// substitution (if any) overlaid — read as two plain table queries and
// merged in code rather than forced through v_daily_timetable, which has
// no per-date filter (see that view's own migration comment for why).
export async function loadPeriodsForTeacher(
  campusId: string,
  staffUserId: string,
  date: string
): Promise<{ error: string | null; periods: PeriodRow[] }> {
  const supabase = await supabaseServer();
  const weekday = new Date(`${date}T00:00:00Z`).getUTCDay();

  const { data: slots, error: slotsError } = await supabase
    .from('timetable_slot')
    .select('id, period_no, section:section_id(name), subject:subject_id(code)')
    .eq('campus_id', campusId)
    .eq('staff_id', staffUserId)
    .eq('weekday', weekday);
  if (slotsError) return { error: "Could not load this teacher's periods.", periods: [] };

  const slotIds = (slots ?? []).map((s) => s.id);
  const { data: subs, error: subsError } =
    slotIds.length > 0
      ? await supabase.from('timetable_substitution').select('slot_id, status, substitute_staff_id').eq('sub_date', date).in('slot_id', slotIds)
      : { data: [] as { slot_id: string; status: string; substitute_staff_id: string }[], error: null };
  if (subsError) return { error: "Could not load today's substitutions.", periods: [] };

  const names = await resolveFullNames(
    supabase,
    (subs ?? []).map((s) => s.substitute_staff_id)
  );
  const subBySlot = new Map((subs ?? []).map((s) => [s.slot_id, s]));

  const periods: PeriodRow[] = (slots ?? [])
    .map((s) => {
      const sub = subBySlot.get(s.id);
      return {
        slotId: s.id,
        periodNo: s.period_no,
        sectionName: one(s.section)?.name ?? '',
        subjectCode: one(s.subject)?.code ?? '',
        substitutionStatus: (sub?.status as 'active' | 'review' | undefined) ?? null,
        substituteName: sub ? (names.get(sub.substitute_staff_id) ?? null) : null,
      };
    })
    .sort((a, b) => a.periodNo - b.periodNo);

  return { error: null, periods };
}

export type Candidate = { staffId: string; fullName: string; isFree: boolean; canTeachSubject: boolean; periodsCoveredToday: number };

// AC1/AC2: the ranked candidate list for one period — is_free first, then
// can_teach, then the fairness term.
export async function loadCandidates(slotId: string, date: string): Promise<{ error: string | null; candidates: Candidate[] }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('suggest_substitutes', { p_slot_id: slotId, p_sub_date: date });
  if (error) return { error: 'Could not load candidates.', candidates: [] };

  const candidates = (data ?? []).map((c) => ({
    staffId: c.staff_id,
    fullName: c.full_name,
    isFree: c.is_free,
    canTeachSubject: c.can_teach_subject,
    periodsCoveredToday: c.periods_covered_today,
  }));
  return { error: null, candidates };
}

export type ReviewRow = {
  id: string;
  subDate: string;
  weekday: number;
  periodNo: number;
  sectionName: string;
  subjectCode: string;
  absentName: string;
  substituteName: string;
};

// AC4: a leave cancellation never deletes a substitution built against it
// — it flips to 'review' instead. This is that worklist, campus-wide and
// not scoped to whichever teacher happens to be selected above.
export async function loadReviewWorklist(campusId: string): Promise<{ error: string | null; rows: ReviewRow[] }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase
    .from('timetable_substitution')
    .select(
      'id, sub_date, absent_staff_id, substitute_staff_id, slot:slot_id(weekday, period_no, subject:subject_id(code), section:section_id(name))'
    )
    .eq('campus_id', campusId)
    .eq('status', 'review')
    .order('sub_date', { ascending: false });
  if (error) return { error: 'Could not load the review worklist.', rows: [] };

  const names = await resolveFullNames(supabase, (data ?? []).flatMap((r) => [r.absent_staff_id, r.substitute_staff_id]));

  const rows = (data ?? []).map((r) => {
    const slot = one(r.slot);
    return {
      id: r.id,
      subDate: r.sub_date,
      weekday: slot?.weekday ?? 0,
      periodNo: slot?.period_no ?? 0,
      sectionName: one(slot?.section ?? null)?.name ?? '',
      subjectCode: one(slot?.subject ?? null)?.code ?? '',
      absentName: names.get(r.absent_staff_id) ?? '',
      substituteName: names.get(r.substitute_staff_id) ?? '',
    };
  });
  return { error: null, rows };
}

export type AssignSubstitutionState = { error: string | null };

// AC1: fillable in 2 taps — pick the period (which already carries
// slotId), then tap a candidate.
export async function assignSubstitution(input: {
  slotId: string;
  subDate: string;
  substituteStaffId: string;
  reason: string;
}): Promise<AssignSubstitutionState> {
  const parsed = assignSubstitutionSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_substitution', {
    p_slot_id: parsed.data.slotId,
    p_sub_date: parsed.data.subDate,
    p_substitute_staff_id: parsed.data.substituteStaffId,
    p_reason: parsed.data.reason,
  });
  if (error) {
    if (error.message.includes('SUBSTITUTE_CLASH')) return { error: 'This teacher already has a class at that time.' };
    if (error.message.includes('SLOT_HAS_NO_TEACHER')) return { error: 'This period has no regular teacher to cover.' };
    if (error.message.includes('SUBSTITUTE_IS_ABSENT_TEACHER')) return { error: 'The absent teacher cannot cover their own period.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to assign substitutes.' };
    return { error: 'Could not assign this substitute.' };
  }

  revalidatePath('/academic-setup/substitutions');
  return { error: null };
}
