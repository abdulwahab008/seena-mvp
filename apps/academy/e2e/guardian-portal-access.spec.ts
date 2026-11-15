import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the office blocks, then restores, a parent\'s portal access to one child', async ({ page }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(1, 'portal-access-e2e');
  const { data: student } = await seed.db.from('student').select('id').eq('tenant_id', seed.tenant).single();
  const { data: user } = await seed.db.auth.admin.createUser({ email: `parent-${seed.tenant.slice(0, 8)}@portal-access.test`, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian, error: gErr } = await seed.db.from('guardian').insert({ tenant_id: seed.tenant, name_en: 'Tariq Mehmood', auth_user_id: user.user!.id }).select('id').single();
  if (gErr) throw gErr;
  const { error: lErr } = await seed.db.from('student_guardian').insert({ tenant_id: seed.tenant, student_id: student!.id, guardian_id: guardian!.id, relationship: 'father', receives_billing: true });
  if (lErr) throw lErr;
  await signInAs(page, seed.email);

  await page.goto(`/students/${student!.id}`);
  const state = page.getByTestId(`guardian-portal-state-${guardian!.id}`);
  await expect(state).toHaveText('portal active');
  page.once('dialog', (d) => d.accept());
  await page.getByTestId(`guardian-portal-toggle-${guardian!.id}`).click();
  await expect(state).toHaveText('portal blocked for this child');
  const { data: link } = await seed.db.from('student_guardian').select('portal_access').eq('guardian_id', guardian!.id).single();
  expect(link!.portal_access).toBe(false);

  await page.getByTestId(`guardian-portal-toggle-${guardian!.id}`).click();
  await expect(state).toHaveText('portal active');
});
