'use server';

import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { tempPassword } from '@/lib/auth/temp-password';

export type ResetSlip = { name: string; grNumber: string; password: string };

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

// Every student with a portal login in the section gets a new temporary
// password and must choose their own at next sign-in. The passwords are
// returned once, for printing; they are not stored anywhere readable.
export async function resetSectionPasswords(sectionId: string): Promise<{ error: string | null; slips?: ResetSlip[] }> {
  if (!z.string().uuid().safeParse(sectionId).success) return { error: 'Choose a section.' };
  const actor = await getCurrentActor();
  if (!actor || !['super_admin', 'owner', 'principal'].includes(actor.role)) return { error: 'Only the owner or a principal can reset passwords.' };

  const supabase = await supabaseServer();
  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('student_id, roll_no, student(name_en, gr_number)')
    .eq('section_id', sectionId)
    .eq('status', 'active');
  const ids = (enrolments ?? []).map((e) => e.student_id);
  if (ids.length === 0) return { error: 'This section has no students.' };

  const admin = supabaseServiceRole();
  const { data: accounts } = await admin.from('student_portal_account').select('student_id, user_id').in('student_id', ids).eq('tenant_id', actor.tenantId);
  const byStudent = new Map((accounts ?? []).map((a) => [a.student_id, a.user_id]));
  if (byStudent.size === 0) return { error: 'No student in this section has a portal login yet.' };

  const slips: ResetSlip[] = [];
  for (const e of [...(enrolments ?? [])].sort((a, b) => (a.roll_no ?? 9999) - (b.roll_no ?? 9999))) {
    const userId = byStudent.get(e.student_id);
    if (!userId) continue;
    // The database decides whether this account is in the caller's scope.
    const { error: scopeError } = await supabase.rpc('user_account_kind', { p_user_id: userId });
    if (scopeError) return { error: 'One of these accounts is outside your campuses.' };
    const password = tempPassword();
    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) return { error: 'Could not reset every password. Try again.' };
    await admin.from('student_portal_account').update({ must_change_password: true }).eq('user_id', userId);
    const s = one(e.student);
    slips.push({ name: s?.name_en ?? '', grNumber: s?.gr_number ?? '', password });
  }
  return { error: null, slips };
}

// Students from the campus's login class upward who have no portal login yet get one. The
// database decides who qualifies and who may do this; the first passwords come back once.
export async function issueStudentLogins(campusId: string): Promise<{ error: string | null; slips?: ResetSlip[] }> {
  if (!z.string().uuid().safeParse(campusId).success) return { error: 'Choose a campus.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('provision_student_accounts', { p_campus_id: campusId });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only the owner or a principal can issue student logins.' : 'Could not issue logins. Try again.' };
  const created = (data ?? []).filter((r) => r.action === 'created' && r.initial_password);
  if (created.length === 0) return { error: 'Every student from the login class upward already has a login.' };
  const { data: students } = await supabase.from('student').select('id, name_en').in('id', created.map((r) => r.student_id));
  const nameOf = new Map((students ?? []).map((s) => [s.id, s.name_en]));
  const slips = created
    .map((r) => ({ name: nameOf.get(r.student_id) ?? '', grNumber: r.gr_number, password: r.initial_password }))
    .sort((a, b) => a.name.localeCompare(b.name));
  return { error: null, slips };
}
