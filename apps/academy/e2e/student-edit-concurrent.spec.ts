import { test, expect, type Page } from '@playwright/test';
import { seedSchoolOwner } from './support/school-owner-seed';

async function signIn(page: Page, email: string, password: string, to: string) {
  await page.goto(`/login?redirectTo=${encodeURIComponent(to)}`);
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(new RegExp(`${to}$`));
  await page.waitForLoadState('networkidle');
}

test('two people editing different fields of one student both keep their change', async ({ browser }) => {
  const { admin, tenantId, campusId, email, password } = await seedSchoolOwner('concurrent-edit');
  const { data: student, error } = await admin
    .from('student')
    .insert({ tenant_id: tenantId, campus_id: campusId, gr_number: 'CE-1', name_en: 'Concurrent Kid', dob: '2015-03-14', gender: 'male' })
    .select('id')
    .single();
  if (error) throw error;
  const url = `/students/${student.id}`;

  const a = await (await browser.newContext()).newPage();
  const b = await (await browser.newContext()).newPage();
  await signIn(a, email, password, url);
  await signIn(b, email, password, url);
  await a.getByTestId('edit-student').click();
  await b.getByTestId('edit-student').click();

  await a.getByLabel("Father's name").fill('Imran Khan');
  await a.getByRole('button', { name: 'Save' }).click();
  await expect(a.getByText('Student details saved.')).toBeVisible();

  await b.getByLabel('Name (Urdu)').fill('کنکرنٹ');
  await b.getByRole('button', { name: 'Save' }).click();
  await expect(b.getByText('Student details saved.')).toBeVisible();

  const { data: saved } = await admin.from('student').select('father_name_en, name_ur').eq('id', student.id).single();
  expect(saved).toEqual({ father_name_en: 'Imran Khan', name_ur: 'کنکرنٹ' });
});
