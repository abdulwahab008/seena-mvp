import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';
import { todayPk } from './support/today';

test('an owner transfers a student between campuses, records vaccinations, merges a duplicate and reads the withdrawal register', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('records-extras-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const north = await must(db.from('campus').insert({ tenant_id, code: `N${runId}`.slice(0, 10), name: 'North Campus' }).select('id').single());
  const session = await must(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await must(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single());
  const base = { tenant_id, session_id: session.id, class_level_id: level.id, capacity: 30 };
  const sectionA = await must(db.from('class_section').insert({ ...base, campus_id, name: 'A' }).select('id').single());
  await must(db.from('class_section').insert({ ...base, campus_id: north.id, name: 'N' }).select('id').single());
  const mkStudent = (gr: string, name: string) =>
    must(db.from('student').insert({ tenant_id, campus_id, gr_number: `${gr}-${runId}`, name_en: name, dob: '2015-01-01', gender: 'female', status: 'active' }).select('id').single());
  const zara = await mkStudent('Z', 'Zara Khan');
  const dup = await mkStudent('ZD', 'Zara Khan');
  const sana = await mkStudent('S', 'Sana Ali');
  const zaraEnrol = await must(db.from('enrolment').insert({ ...base, campus_id, section_id: sectionA.id, student_id: zara.id, capacity: undefined }).select('id').single());
  await must(db.from('section_membership_history').insert({ enrolment_id: zaraEnrol.id, section_id: sectionA.id, from_date: '2026-08-01' }).select('id').single());
  await must(db.from('enrolment').insert({ ...base, campus_id, section_id: sectionA.id, student_id: sana.id, status: 'left', left_on: todayPk(), capacity: undefined }).select('id').single());
  const mother = await must(db.from('guardian').insert({ tenant_id, name_en: 'Mother of Zara', phone_e164: '+923004440001' }).select('id').single());
  await must(db.from('student_guardian').insert({ tenant_id, student_id: dup.id, guardian_id: mother.id, relationship: 'mother', is_primary: true, receives_billing: true }).select('student_id').single());

  await signInAs(page, owner.email);

  await page.goto('/students/transfers');
  await page.getByLabel('GR number').fill(`Z-${runId}`);
  await page.getByLabel('New campus and section').selectOption({ label: 'North Campus · Class 5 N' });
  await page.getByLabel('Reason').fill('Family moved north');
  await page.getByRole('button', { name: 'Request transfer' }).click();
  await expect(page.getByText('Transfer requested.', { exact: false })).toBeVisible();
  await page.getByRole('button', { name: 'Decide' }).click();
  await page.getByRole('button', { name: 'Approve transfer' }).click();
  await expect(page.getByTestId('transfer-row')).toContainText('Transferred');

  await page.goto('/students/vaccinations');
  await page.getByLabel('GR number').fill(`Z-${runId}`);
  await page.getByLabel('Vaccine').fill('Typhoid');
  const soon = new Date(Date.now() + 5 * 86400000).toISOString().slice(0, 10);
  await page.getByLabel('Due on').fill(soon);
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Vaccination saved.')).toBeVisible();
  await expect(page.getByTestId('vaccination-due')).toContainText('Typhoid');

  await page.goto('/students/merge');
  await page.getByLabel('GR number to keep').fill(`Z-${runId}`);
  await page.getByLabel('Duplicate GR number').fill(`ZD-${runId}`);
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.getByTestId('merge-preview')).toContainText('student guardian: 1');
  await page.getByRole('button', { name: 'Merge', exact: true }).click();
  await expect(page.getByText('Students merged.')).toBeVisible();

  await page.goto('/students/withdrawals');
  await expect(page.getByTestId('withdrawal-row')).toContainText('Sana Ali');
  await expect(page.getByTestId('kpi-withdrawn')).toHaveText('1');
});
