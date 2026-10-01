import type { SupabaseClient } from '@supabase/supabase-js';

/** Roles that run the exam office; mirrors app.fn_exam_office() in the database. */
export const EXAM_OFFICE_ROLES = ['super_admin', 'owner', 'principal', 'exam_controller'] as const;

export type ExamOfficeScope = {
  userId: string;
  role: string;
  canWrite: boolean;
  campus: { id: string; name: string; timezone: string } | null;
  session: { id: string; name: string } | null;
};

/**
 * The acting user's role plus the alphabetically-first active campus and that
 * campus's current session: the derivation every other campus-scoped exam page
 * uses (see exams/terms/page.tsx). The database re-checks role and campus on
 * every call regardless of what a page renders.
 */
export async function getExamOfficeScope(supabase: SupabaseClient): Promise<ExamOfficeScope> {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = (appUser?.app_role as string | undefined) ?? 'none';
  const { data: campuses } = await supabase.from('campus').select('id, name, timezone').eq('status', 'active').order('code').limit(1);
  const campus = campuses?.[0] ?? null;
  const { data: sessions } = campus
    ? await supabase.from('academic_session').select('id, name').or(`campus_id.eq.${campus.id},campus_id.is.null`).eq('is_current', true).order('starts_on', { ascending: false }).limit(1)
    : { data: null };
  return {
    userId: user!.id,
    role,
    canWrite: (EXAM_OFFICE_ROLES as readonly string[]).includes(role),
    campus,
    session: sessions?.[0] ?? null,
  };
}

export const one = <T>(v: T | T[] | null | undefined): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));
