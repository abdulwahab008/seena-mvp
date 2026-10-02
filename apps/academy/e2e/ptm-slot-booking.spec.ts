import { test, expect, type Page } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-N11: two parents see the same stale slot list; the second to click gets "slot just taken" with a refreshed list.

test('two parents race for one PTM slot: one books, the other is told the slot was just taken', async ({ page, browser, baseURL }) => {
  test.setTimeout(150000);
  const { db, owner$, tenant, campusId, challans } = await seedFeesTenant(2, 'ptm-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const { data: enrolments } = await db.from('enrolment').select('id, student_id').in('id', challans.map((c) => c.enrolment_id));

  const teacherEmail = `teacher-${randomUUID().slice(0, 8)}@ptm-e2e.test`;
  const { data: teacherUser } = await db.auth.admin.createUser({ email: teacherEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: teacherUser.user!.id, tenant_id: tenant, app_role: 'class_teacher', full_name: 'Miss Class Teacher' });
  await db.from('section_class_teacher').insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, section_id: section!.id, staff_id: teacherUser.user!.id, effective_from: '2000-01-01' });

  const eventDate = new Date(Date.now() + 5 * 86400000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  const { data: eventId, error: eventError } = await owner$.rpc('create_ptm_event', { p_campus_id: campusId, p_title: 'Term 1 PTM', p_event_date: eventDate, p_start_time: '10:00', p_cutoff_hours: 24 });
  expect(eventError).toBeNull();
  const { error: slotError } = await owner$.rpc('generate_ptm_slots', { p_event_id: eventId as string, p_teacher_ids: [teacherUser.user!.id], p_start_time: '10:00', p_end_time: '10:30' });
  expect(slotError).toBeNull();

  const mkParent = async (i: number) => {
    const email = `parent${i}-${randomUUID().slice(0, 8)}@ptm-e2e.test`;
    const { data: user } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
    const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: `PTM Parent ${i}`, phone_e164: `+92300555000${i}`, auth_user_id: user.user!.id }).select('id').single();
    await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolments![i - 1]!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });
    return email;
  };
  const emailA = await mkParent(1);
  const emailB = await mkParent(2);

  const signIn = async (p: Page, email: string) => {
    await p.goto('/login');
    await p.waitForLoadState('networkidle');
    await p.getByLabel('Email').fill(email);
    await p.getByLabel('Password').fill(SEED_PASSWORD);
    await p.getByRole('button', { name: 'Sign in' }).click();
    await p.waitForURL(/\/portal/);
  };

  await signIn(page, emailA);
  const ctxB = await browser.newContext({ baseURL: baseURL ?? undefined });
  const pageB = await ctxB.newPage();
  await signIn(pageB, emailB);

  await page.goto('/portal/ptm');
  await pageB.goto('/portal/ptm');
  await expect(page.getByTestId('ptm-slot')).toHaveCount(3);
  await expect(pageB.getByTestId('ptm-slot')).toHaveCount(3);
  await expect(page.getByTestId('ptm-cutoff')).toContainText('Booking closes');

  // Parent A takes the first slot.
  await page.getByTestId('ptm-book').first().click();
  await expect(page.getByTestId('ptm-cancel')).toHaveCount(1);

  // Parent B's list is stale: the same slot still shows as free. Clicking it is refused, and the list is refreshed in place.
  await pageB.getByTestId('ptm-book').first().click();
  await expect(pageB.getByTestId('ptm-message')).toHaveText('slot just taken');
  await expect(pageB.locator('[data-testid="ptm-slot"][data-available="false"]')).toHaveCount(1);
  await expect(pageB.locator('[data-testid="ptm-slot"][data-available="true"]')).toHaveCount(2);

  const { count } = await db.from('ptm_booking').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant).eq('status', 'confirmed');
  expect(count).toBe(1);
  const { data: msgs } = await db.from('message').select('id').eq('tenant_id', tenant).like('idempotency_key', 'ptm_confirm:%');
  expect(msgs).toHaveLength(1);

  // A cancels: the slot is bookable at once, and B can take it.
  await page.getByTestId('ptm-cancel').click();
  await expect(page.getByTestId('ptm-cancel')).toHaveCount(0);
  await pageB.reload();
  await pageB.getByTestId('ptm-book').first().click();
  await expect(pageB.getByTestId('ptm-cancel')).toHaveCount(1);
  await ctxB.close();
});
