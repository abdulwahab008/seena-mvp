import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('a teacher schedules a live class and a student joins it and is counted present', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(1, 'live-class');
  const { data: enrolment } = await seed.db.from('enrolment').select('student_id').eq('campus_id', seed.campusId).single();
  const studentEmail = `student.${enrolment!.student_id}@student.seena.local`;
  const { data: su } = await seed.db.auth.admin.createUser({ email: studentEmail, password: SEED_PASSWORD, email_confirm: true });
  await seed.db.from('student_portal_account').insert({ tenant_id: seed.tenant, campus_id: seed.campusId, student_id: enrolment!.student_id, user_id: su.user!.id, must_change_password: false });

  await signInAs(page, seed.email);
  await page.goto('/live-classes');
  await page.getByLabel('Section').selectOption({ index: 1 });
  await page.getByLabel('Title').fill('Fractions live');
  const inFiveMinutes = new Date(Date.now() + 5 * 60_000);
  await page.getByLabel('Starts at').fill(new Date(inFiveMinutes.getTime() - inFiveMinutes.getTimezoneOffset() * 60000).toISOString().slice(0, 16));
  await page.getByLabel('Meeting link').fill('https://meet.example.com/abc-defg');
  await page.getByRole('button', { name: 'Schedule' }).click();
  await expect(page.getByText('Live class scheduled.')).toBeVisible();
  await expect(page.getByTestId('live-class-row')).toContainText('Fractions live');

  const sctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  await sctx.route('https://meet.example.com/**', (route) => route.fulfill({ body: 'meeting room' }));
  const sp = await sctx.newPage();
  await sp.goto('/login');
  await sp.waitForLoadState('networkidle');
  await sp.getByLabel('Email').fill(studentEmail);
  await sp.getByLabel('Password').fill(SEED_PASSWORD);
  await sp.getByRole('button', { name: 'Sign in' }).click();
  await sp.waitForURL(/\/student/);
  await sp.goto('/student/live-classes');
  const popup = sp.waitForEvent('popup');
  await sp.getByRole('button', { name: 'Join' }).click();
  const room = await popup;
  await room.waitForLoadState();
  expect(room.url()).toBe('https://meet.example.com/abc-defg');
  await expect(sp.getByText('You are marked present.')).toBeVisible();
  await sctx.close();

  await page.reload();
  await expect(page.getByTestId('live-class-row').getByRole('cell').nth(3)).toHaveText('1');
});
