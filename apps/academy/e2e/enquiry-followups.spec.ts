import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('an owner schedules a follow-up on an enquiry and marks it done with the outcome', async ({ page }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(1, 'followup-e2e');
  const { data: session } = await seed.db.from('academic_session').select('id').eq('tenant_id', seed.tenant).limit(1).single();
  const { data: cls } = await seed.db.from('class_level').select('id').eq('tenant_id', seed.tenant).eq('code', '1').single();
  const { data: enquiry, error } = await seed.db
    .from('admission_enquiry')
    .insert({
      tenant_id: seed.tenant,
      campus_id: seed.campusId,
      session_id: session!.id,
      child_name: 'Hira Malik',
      dob: '2019-05-10',
      class_applied_id: cls!.id,
      parent_name: 'Malik Sahab',
      phone_e164: '+923001234567',
      source: 'walk_in',
    })
    .select('enquiry_no')
    .single();
  if (error) throw error;
  const no = enquiry!.enquiry_no;
  await signInAs(page, seed.email);

  await page.goto('/admissions/enquiries');
  await page.getByTestId(`schedule-followup-${no}`).click();
  await page.getByLabel('Follow up on').fill('2026-01-05T10:30');
  await page.getByLabel('Follow up by').selectOption('whatsapp');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Follow-up scheduled.')).toBeVisible();

  await page.goto('/admissions/follow-ups');
  const row = page.getByTestId(`followup-${no}`);
  await expect(row).toContainText('Hira Malik');
  await expect(row).toContainText('WhatsApp');
  await expect(row).toContainText('Overdue');
  await page.getByTestId(`complete-followup-${no}`).click();
  await page.getByLabel('What happened').selectOption('visit_scheduled');
  await page.getByLabel('Note').fill('Coming Saturday');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Follow-up done.')).toBeVisible();
  await expect(page.getByTestId(`followup-done-${no}`)).toContainText('Visit booked · Coming Saturday');
  await expect(row).toHaveCount(0);
});
