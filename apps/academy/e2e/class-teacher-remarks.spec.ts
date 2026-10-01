import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-J10: a class teacher works through a section's remarks: library pick, 250-character cap, apply to selected,
// an Urdu/English mixed remark, and the remarks_required guard on bulk report cards.

test('a class teacher writes remarks with the library, the 250 cap and apply-to-selected', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, tenant, campusId } = await seedFeesTenant(5, 'remark-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const { data: term, error: termError } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'Term 1', p_sequence: 1, p_weight_pct: 100 });
  expect(termError).toBeNull();

  const email = `classteacher-${tenant.slice(0, 8)}@remark-e2e.test`;
  const { data: created } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: created.user!.id, tenant_id: tenant, app_role: 'class_teacher', full_name: 'Class Teacher' });
  await db.from('user_campus').insert({ user_id: created.user!.id, tenant_id: tenant, campus_id: campusId });
  await db.from('section_class_teacher').insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, section_id: section!.id, staff_id: created.user!.id, effective_from: '2000-01-01' });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/remarks');
  await expect(page.getByTestId('remark-row')).toHaveCount(5);
  await expect(page.getByTestId('missing-count')).toHaveText('5');

  // The standard library, then a pick for the first student.
  await page.getByTestId('seed-library').click();
  await expect(page.getByTestId('library-list').locator('li')).toHaveCount(8);
  const first = page.getByTestId('remark-row').first();
  await first.getByLabel(/^Library remark for/).selectOption({ index: 1 });
  await expect(first.getByLabel(/^Remark for/)).not.toHaveValue('');
  await first.getByTestId('save-remark').click();
  await expect(page.getByTestId('missing-count')).toHaveText('4');

  // 300 characters stop at 250, with a live counter.
  const second = page.getByTestId('remark-row').nth(1);
  await second.getByLabel(/^Remark for/).fill('a'.repeat(300));
  await expect(second.getByTestId('remark-counter')).toHaveText('250/250');
  await expect(second.getByLabel(/^Remark for/)).toHaveValue('a'.repeat(250));

  // A mixed Urdu / English remark with digits is saved as written.
  const mixed = 'طالب علم کی کارکردگی 85% بہتر ہے, Grade A';
  await second.getByLabel(/^Remark for/).fill(mixed);
  await second.getByTestId('save-remark').click();
  await expect(page.getByTestId('missing-count')).toHaveText('3');
  const { data: saved } = await db.from('term_remark').select('remark_text, remark_lang').eq('tenant_id', tenant).eq('remark_lang', 'ur').single();
  expect(saved!.remark_text).toBe(mixed);

  // Apply one remark to the three that are left.
  for (const i of [2, 3, 4]) await page.getByTestId('remark-row').nth(i).getByRole('checkbox').check();
  await page.getByLabel('Remark for the selection', { exact: true }).fill('A satisfactory term. Keep working steadily.');
  await page.getByTestId('apply-selected').click();
  await expect(page.getByTestId('missing-count')).toHaveText('0');

  // With remarks_required on, a missing remark would block bulk generation: clear one and the batch is refused naming its GR number.
  const { data: enrolments } = await db.from('enrolment').select('id, student:student_id(gr_number)').eq('section_id', section!.id);
  const victim = enrolments![0]!;
  await db.from('term_remark').delete().eq('enrolment_id', victim.id);
  await owner$.rpc('set_remarks_required', { p_campus_id: campusId, p_required: true });
  const { error: batchError } = await owner$.rpc('start_report_card_batch', { p_exam_term_id: term as string, p_scope: 'section', p_target_id: section!.id });
  expect(batchError?.message).toContain('REMARKS_MISSING');
  const grNumber = (Array.isArray(victim.student) ? victim.student[0] : victim.student)!.gr_number;
  expect(batchError?.details).toContain(grNumber);
});
