import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the exam office prints admit cards for a section once the datesheet is published', async ({ page, context }) => {
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(2, 'admit');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'MTH', name_en: 'Mathematics', name_ur: 'ریاضی' }).select('id').single();
  const { data: cs } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: subject!.id, p_weekly_periods: 5 });
  const { data: term } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 100 });
  await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId });
  const { data: es } = await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: cs as string, p_components: [{ component: 'theory', max_marks: 100, pass_marks: 33 }] });
  const { data: ds } = await owner$.rpc('create_datesheet', { p_campus_id: campusId, p_exam_term_id: term as string, p_title: 'First Term datesheet' });
  await owner$.rpc('save_datesheet_slot', { p_datesheet_id: ds as string, p_exam_subject_id: es as string, p_exam_date: '2026-12-08', p_start_time: '09:00', p_end_time: '11:00' });
  const { error } = await owner$.rpc('publish_datesheet', { p_datesheet_id: ds as string });
  if (error) throw error;

  await signInAs(page, email);
  await page.goto('/exams/datesheet');
  await expect(page.getByTestId('datesheet-status')).toHaveText('published');
  const opened = context.waitForEvent('request', (r) => r.url().includes('/api/exams/admit-cards?'));
  await page.getByRole('button', { name: 'Print admit cards' }).click();
  const response = await page.request.get((await opened).url());
  expect(response.status()).toBe(200);
  expect(response.headers()['content-type']).toBe('application/pdf');
});
