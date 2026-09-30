import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
export const SEED_PASSWORD = 'e2e-test-password-123!';

function must<T>(r: { data: T; error: { message: string } | null }, what: string): T {
  if (r.error) throw new Error(`${what}: ${r.error.message}`);
  return r.data;
}

// A school with an owner who can sign in, a published 8,500 PKR monthly
// structure, and `students` enrolled children each holding this month's challan.
export async function seedFeesTenant(students: number, label: string) {
  const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@${label}.test`;
  const tenant = must(await db.rpc('provision_tenant', { p_slug: `${label}-${runId}`, p_legal_name: `${label} ${runId}`, p_owner_email: email }), 'provision') as string;
  const { data: owner } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: owner.user!.id, tenant_id: tenant, app_role: 'owner', full_name: 'Seed Owner' });
  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  await db.from('user_campus').insert({ user_id: owner.user!.id, tenant_id: tenant, campus_id: campus!.id });
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();

  const owner$ = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  await owner$.auth.signInWithPassword({ email, password: SEED_PASSWORD });
  const { data: others } = await db.from('class_level').select('id').eq('tenant_id', tenant).neq('code', '1');
  for (const o of others ?? []) must(await owner$.rpc('set_class_level_active', { p_id: o.id, p_is_active: false }), 'deactivate level');
  const section = must(await owner$.rpc('create_section', { p_campus_id: campus!.id, p_session_id: session!.id, p_class_level_id: level!.id, p_name: 'A', p_capacity: 60 }), 'section');
  must(await owner$.rpc('seed_default_fee_heads', { p_tenant_id: tenant }), 'fee heads');
  const { data: head } = await db.from('fee_head').select('id').eq('tenant_id', tenant).eq('code', 'TUITION').single();
  const structure = must(await owner$.rpc('create_draft_structure', { p_campus_id: campus!.id, p_session_id: session!.id }), 'structure');
  must(await owner$.rpc('add_structure_line', { p_structure_id: structure as string, p_class_id: level!.id, p_fee_head_id: head!.id, p_amount_paisa: 850000, p_frequency: 'monthly' }), 'line');
  must(await owner$.rpc('publish_fee_structure', { p_structure_id: structure as string }), 'publish');

  const enrolIds: string[] = [];
  for (let i = 1; i <= students; i++) {
    const s = must(await owner$.rpc('create_student', { p_campus_id: campus!.id, p_name_en: `${label} Kid ${i}`, p_dob: '2015-01-01', p_gender: 'male' }), 'student');
    enrolIds.push(must(await owner$.rpc('enrol_student', { p_section_id: section as string, p_student_id: s as string }), 'enrol') as string);
  }
  const now = new Date();
  must(await owner$.rpc('generate_challans', { p_campus_id: campus!.id, p_session_id: session!.id, p_period: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 15)).toISOString().slice(0, 10), p_dry_run: false }), 'challans');
  const { data: challans } = await db.from('fee_challan').select('id, challan_no, enrolment_id').in('enrolment_id', enrolIds);
  return { db, owner$, email, tenant, campusId: campus!.id as string, challans: challans ?? [] };
}
