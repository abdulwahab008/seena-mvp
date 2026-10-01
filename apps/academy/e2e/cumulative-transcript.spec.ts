import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-J13: a cumulative transcript across sessions and campuses.
//
//   AC1  every session, in order, the campus named against each.
//   AC2  a session left in March is annotated "incomplete — left March 2023".
//   AC4  issuing prints the serial, officer and date, and a register row exists.

test('a Principal reviews the history across campuses and issues a transcript', async ({ page }) => {
  test.setTimeout(150000);
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(1, 'trans-e2e');
  const { data: enrolment } = await db.from('enrolment').select('id, student_id, class_level_id').eq('id', challans[0]!.enrolment_id).single();
  const { data: student } = await db.from('student').select('name_en, gr_number').eq('id', enrolment!.student_id).single();

  // An older campus that has since closed, and two earlier sessions there.
  const { data: oldCampus } = await db.from('campus').insert({ tenant_id: tenant, name: 'Old Town Campus', code: 'OLD', status: 'archived' }).select('id').single();
  const sessions = [
    { name: '2021-22', starts_on: '2021-04-01', ends_on: '2022-03-31', left: null },
    { name: '2022-23', starts_on: '2022-04-01', ends_on: '2023-03-31', left: '2023-03-15' },
  ];
  for (const s of sessions) {
    const { data: ses } = await db
      .from('academic_session')
      .insert({ tenant_id: tenant, campus_id: oldCampus!.id, name: s.name, starts_on: s.starts_on, ends_on: s.ends_on, status: 'closed' })
      .select('id')
      .single();
    const { data: sec } = await db
      .from('class_section')
      .insert({ tenant_id: tenant, campus_id: oldCampus!.id, session_id: ses!.id, class_level_id: enrolment!.class_level_id, name: 'A', capacity: 40 })
      .select('id')
      .single();
    const { error } = await db.from('enrolment').insert({
      tenant_id: tenant, campus_id: oldCampus!.id, session_id: ses!.id, student_id: enrolment!.student_id, class_level_id: enrolment!.class_level_id,
      section_id: sec!.id, status: s.left ? 'left' : 'active', joined_on: s.starts_on, left_on: s.left,
    });
    expect(error).toBeNull();
  }
  void campusId;

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/transcripts');
  await page.getByTestId('transcript-search').fill(student!.gr_number);
  await page.getByTestId('transcript-search-go').click();
  await page.getByTestId(`transcript-pick-${student!.gr_number}`).click();

  const preview = page.getByTestId('transcript-preview');
  await expect(preview).toBeVisible();
  await expect(page.getByTestId('transcript-session-2021-22')).toContainText('Old Town Campus (closed)');
  await expect(page.getByTestId('transcript-standing-2022-23')).toContainText('incomplete — left March 2023');
  const names = await preview.locator('[data-testid^="transcript-session-"]').evaluateAll((rows) => rows.map((r) => r.querySelector('td')?.textContent));
  expect(names.slice(0, 2)).toEqual(['2021-22', '2022-23']);

  await page.getByTestId('transcript-purpose').selectOption('College admission');
  await page.getByTestId('issue-transcript').click();
  await expect(page.getByTestId('issued-notice')).toBeVisible({ timeout: 60000 });
  const serial = (await page.getByTestId('issued-serial').textContent())!;
  expect(serial).toMatch(/^TRN-\d{4}-000001$/);

  const href = await page.getByTestId('issued-download').getAttribute('href');
  const res = await page.request.get(href!);
  expect(res.status()).toBe(200);
  expect((await res.body()).subarray(0, 4).toString()).toBe('%PDF');

  const { data: register } = await db.from('transcript_issue').select('serial_no, purpose, issued_by_name, status, issued_on').eq('tenant_id', tenant);
  expect(register).toHaveLength(1);
  expect(register![0]).toMatchObject({ serial_no: serial, purpose: 'College admission', status: 'issued' });
  expect(register![0]!.issued_by_name).toBeTruthy();
});
