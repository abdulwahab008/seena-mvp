import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { seedHrTenant, signInAs, HR_SEED_PASSWORD } from './support/hr-seed';

// FR-D15: HR records a show-cause notice, a response is added as a NEW entry, rows cannot be deleted,
// and a Principal who did not issue anything neither sees the section nor can read the table.

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

test('the disciplinary trail is restricted and append-only', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const { db, tenantId, mkUser, owner } = await seedHrTenant('disc-e2e');
  const hr = await mkUser('hrmanager', 'hr_manager');
  const principal = await mkUser('principal', 'principal');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: {} });

  await signInAs(page, hr.email);
  await page.goto(`/staff/${teacher.staffId}`);
  await page.getByLabel('Type of action').selectOption('show_cause');
  await page.getByLabel('Days allowed to respond').fill('7');
  await page.getByLabel('What happened').fill('Absent without notice on 12 July.');
  await page.getByTestId('issue-disciplinary').click();
  await expect(page.getByTestId('disciplinary-row')).toHaveCount(1);
  await expect(page.getByTestId('disciplinary-row')).toContainText('Show-cause notice');

  await page.getByTestId('open-correction').click();
  await page.getByLabel('Staff response').fill('I was at the board office.');
  await page.getByTestId('save-correction').click();
  await expect(page.getByTestId('disciplinary-row')).toHaveCount(2);
  await expect(page.getByTestId('disciplinary-list')).toContainText('superseded');
  await expect(page.getByTestId('disciplinary-list')).toContainText('I was at the board office.');

  // Rows cannot be deleted or edited, even by HR through the API.
  const hr$ = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  await hr$.auth.signInWithPassword({ email: hr.email, password: HR_SEED_PASSWORD });
  const del = await hr$.from('staff_disciplinary').delete().eq('tenant_id', tenantId);
  expect(del.error).not.toBeNull();
  const { count } = await db.from('staff_disciplinary').select('id', { count: 'exact', head: true }).eq('tenant_id', tenantId);
  expect(count).toBe(2);

  // A Principal who issued nothing: no section on the profile, zero rows from the API.
  const pctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const pp = await pctx.newPage();
  await signInAs(pp, principal.email);
  await pp.goto(`/staff/${teacher.staffId}`);
  await expect(pp.getByTestId('staff-name')).toBeVisible();
  await expect(pp.getByTestId('disciplinary-section')).toHaveCount(0);
  const principal$ = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  await principal$.auth.signInWithPassword({ email: principal.email, password: HR_SEED_PASSWORD });
  const read = await principal$.from('staff_disciplinary').select('id');
  expect(read.data).toEqual([]);
  await pctx.close();
  void owner;
});
