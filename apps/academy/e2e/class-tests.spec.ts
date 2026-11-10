import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('a teacher sets a class test, enters marks and texts results to parents', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('class-tests-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const session = await must(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await must(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single());
  const base = { tenant_id, campus_id, session_id: session.id, class_level_id: level.id };
  const section = await must(db.from('class_section').insert({ ...base, name: 'A', capacity: 30 }).select('id').single());
  const ids: Record<string, string> = {};
  for (const name of ['Bilal Ahmed', 'Fatima Noor']) {
    const s = await must(db.from('student').insert({ tenant_id, campus_id, gr_number: `${name[0]}-${runId}`, name_en: name, dob: '2015-01-01', gender: 'male', status: 'active' }).select('id').single());
    ids[name] = s.id;
    await must(db.from('enrolment').insert({ ...base, section_id: section.id, student_id: s.id }).select('id').single());
  }
  const father = await must(db.from('guardian').insert({ tenant_id, name_en: 'Ahmed', phone_e164: '+923004445556' }).select('id').single());
  await must(db.from('student_guardian').insert({ tenant_id, student_id: ids['Bilal Ahmed'], guardian_id: father.id, relationship: 'father', is_primary: true, receives_billing: true }).select('student_id').single());

  await signInAs(page, owner.email);
  await page.goto('/exams/class-tests');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Class and section').selectOption({ label: 'Class 5 A' });
  await page.getByLabel('Test name').fill('Weekly test 1');
  await page.getByLabel('Total marks').fill('20');
  await page.getByRole('button', { name: 'Create test' }).click();
  await expect(page.getByRole('heading', { name: 'Weekly test 1' })).toBeVisible();

  await page.getByLabel('Marks for Bilal Ahmed').fill('18');
  await page.getByLabel('Fatima Noor absent').check();
  await page.getByRole('button', { name: 'Save marks' }).click();
  await expect(page.getByText('Marks saved.')).toBeVisible();
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('Average18.0');

  await page.getByRole('button', { name: 'Send results by SMS' }).click();
  await expect(page.getByText('Queued 1 SMS; 1 had no parent phone.')).toBeVisible();
  const { data } = await db.from('message').select('body').eq('tenant_id', tenant_id).like('idempotency_key', 'class-test:%');
  expect(data?.[0]?.body).toContain('Bilal Ahmed scored 18/20 in Weekly test 1');
});
