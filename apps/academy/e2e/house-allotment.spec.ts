import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-C06: a Principal creates houses, auto-assigns students (siblings together), moves one mid-year and the points stay put.

test('a Principal creates houses, auto-assigns with sibling affinity and a move keeps old points on the old house', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId, email } = await seedFeesTenant(4, 'house-e2e');
  const { data: students } = await db.from('student').select('id, gr_number').eq('tenant_id', tenant).order('gr_number');
  expect(students).toHaveLength(4);
  // The first two students are siblings.
  const { data: family } = await db.from('family_group').insert({ tenant_id: tenant }).select('id').single();
  await db.from('student').update({ family_group_id: family!.id }).in('id', [students![0]!.id, students![1]!.id]);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/houses');
  for (const name of ['Iqbal', 'Jinnah']) {
    await page.getByLabel('House name').fill(name);
    await page.getByTestId('create-house').click();
    await expect(page.getByTestId('house-table')).toContainText(name);
  }

  await page.getByTestId('auto-assign').click();
  await expect(page.getByTestId('auto-assign-result')).toContainText('Placed 4 students');

  const { data: placed } = await db.from('student').select('id, house_id').eq('tenant_id', tenant);
  const byId = new Map(placed!.map((s) => [s.id, s.house_id]));
  expect(byId.get(students![0]!.id)).toBe(byId.get(students![1]!.id));
  const { data: reason } = await db.from('student_house_history').select('reason').eq('student_id', students![1]!.id).single();
  expect(reason!.reason).toBe('sibling_match');

  // Placement is dated on the school's calendar day (Asia/Karachi, UTC+5), which is already
  // "tomorrow" in UTC for part of every day, so the spec must date things the same way.
  const karachiDay = (offsetDays = 0) =>
    new Date(Date.now() + offsetDays * 86400000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

  // Points earned in November stay with the house of the day, whatever happens in February.
  const target = students![2]!;
  const { data: hist } = await db.from('student_house_history').select('house_id').eq('student_id', target.id).is('to_date', null).single();
  const { error: awardError } = await owner$.rpc('award_house_points', { p_student_id: target.id, p_points: 10, p_awarded_on: karachiDay() });
  expect(awardError).toBeNull();
  const { data: other } = await db.from('house').select('id').eq('campus_id', campusId).neq('id', hist!.house_id).single();
  const future = karachiDay(3);
  await page.reload();
  await page.locator('#moveGr').fill(target.gr_number);
  await page.getByLabel('New house').selectOption(other!.id);
  await page.getByLabel('Effective from').fill(future);
  await page.getByTestId('move-student').click();
  await expect.poll(async () => (await db.from('student').select('house_id').eq('id', target.id).single()).data?.house_id).toBe(other!.id);
  const { data: pts } = await db.from('house_point').select('house_id').eq('student_id', target.id).single();
  expect(pts!.house_id).toBe(hist!.house_id);
});
