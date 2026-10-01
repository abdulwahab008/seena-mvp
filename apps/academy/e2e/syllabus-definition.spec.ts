import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H08: build a syllabus, reorder a chapter, and copy it to next year's session.

test('an owner builds, reorders and copies a syllabus', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant } = await seedFeesTenant(0, 'syl-e2e');
  await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' });
  const { data: session } = await db.from('academic_session').select('id, starts_on').eq('tenant_id', tenant).single();
  const nextStart = new Date(session!.starts_on + 'T00:00:00Z');
  nextStart.setUTCFullYear(nextStart.getUTCFullYear() + 1);
  const nextEnd = new Date(nextStart);
  nextEnd.setUTCFullYear(nextEnd.getUTCFullYear() + 1);
  nextEnd.setUTCDate(nextEnd.getUTCDate() - 1);
  const { data: next } = await db.from('academic_session').insert({ tenant_id: tenant, name: 'Next year', starts_on: nextStart.toISOString().slice(0, 10), ends_on: nextEnd.toISOString().slice(0, 10) }).select('id').single();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
  await page.goto('/academic-setup/syllabus');

  for (const [i, title] of ['Motion', 'Force', 'Energy'].entries()) {
    await page.getByLabel('Chapter title').fill(title);
    await page.getByLabel('Planned periods').first().fill(String(8 + i));
    await page.getByTestId('add-unit').click();
    await expect(page.getByTestId('syllabus-unit')).toHaveCount(i + 1);
  }
  await expect(page.getByTestId('syllabus-unit').nth(2)).toContainText('3. Energy');

  await page.getByLabel('Topic title').first().fill('Speed and velocity');
  await page.getByRole('button', { name: 'Add topic' }).first().click();
  await expect(page.getByTestId('syllabus-unit').first()).toContainText('1.1 Speed and velocity');

  await page.getByLabel('Move Energy up').click();
  await expect(page.getByTestId('syllabus-unit').nth(1)).toContainText('2. Energy');
  await expect(page.getByTestId('syllabus-unit').nth(2)).toContainText('3. Force');

  await page.getByLabel('Copy to session').selectOption(next!.id);
  await page.getByTestId('clone-syllabus').click();
  await expect.poll(async () => (await db.from('syllabus_unit').select('id', { count: 'exact', head: true }).eq('session_id', next!.id)).count).toBe(3);
  const { data: cloned } = await db.from('syllabus_unit').select('title, sequence, source_unit_id').eq('session_id', next!.id).order('sequence');
  expect(cloned!.map((u) => u.title)).toEqual(['Motion', 'Energy', 'Force']);
  expect(cloned!.every((u) => u.source_unit_id)).toBe(true);
});
