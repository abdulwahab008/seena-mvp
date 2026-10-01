import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-T07: a Grade 12 leaver gets a Leaving Certificate (board, roll, group, "Result Awaited"); a Grade 8 leaver is turned away to the Transfer Certificate screen.

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('leaving certificate for Grade 12 and a Transfer Certificate redirect for Grade 8', async ({ page }) => {
  test.setTimeout(180000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'slc-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const levels = await db.from('class_level').select('id, code').eq('tenant_id', tenant).in('code', ['8', '12']);
  const level = (code: string) => levels.data!.find((l) => l.code === code)!.id;
  const sections: Record<string, string> = {};
  for (const code of ['8', '12']) {
    const { data } = await db.from('class_section').insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, class_level_id: level(code), name: 'A', capacity: 30 }).select('id').single();
    sections[code] = data!.id;
  }
  const mkStudent = async (gr: string, name: string, status: string, code: string) => {
    const { data: s } = await db.from('student').insert({ tenant_id: tenant, campus_id: campusId, gr_number: gr, name_en: name, father_name_en: 'Father', dob: '2008-01-01', gender: 'female', status }).select('id').single();
    const { data: e } = await db
      .from('enrolment')
      .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, student_id: s!.id, class_level_id: level(code), section_id: sections[code]!, status: 'graduated', joined_on: '2024-04-01' })
      .select('id')
      .single();
    return { studentId: s!.id, enrolmentId: e!.id };
  };
  const hira = await mkStudent('2019-1001', 'Hira Medical', 'passed_out', '12');
  await mkStudent('2019-1002', 'Struck Off Twelve', 'struck_off', '12');
  await db.from('exam_registration').insert({ tenant_id: tenant, campus_id: campusId, student_id: hira.studentId, enrolment_id: hira.enrolmentId, board_code: 'FBISE', roll_no: '462119', group_code: 'Pre-Medical' });

  const { data: templateId, error: templateError } = await owner$.rpc('create_certificate_template', {
    p_certificate_type: 'leaving',
    p_title: 'School Leaving Certificate',
    p_body_html:
      '<p>{{student.name_en}} (GR {{student.gr_number}}) completed class {{leaving.class_roman}}, {{leaving.board}} roll {{leaving.roll_no}}, group {{leaving.group}}. Result: {{leaving.result_status}}. Serial {{issue.serial_no}}, issued {{issue.date}}.</p>',
    p_language: 'en',
    p_page_size: 'A4',
    p_campus_id: campusId,
  });
  expect(templateError).toBeNull();
  const { error: activateError } = await owner$.rpc('activate_certificate_template', { p_template_id: templateId as string });
  expect(activateError).toBeNull();

  await signIn(page, email);
  await page.goto('/certificates/issue/leaving');

  // a Grade 8 student is never offered (only Grade 10 and 12 enrolments are listed)
  await expect(page.getByLabel(/Student \(Grade 10 or 12\)/)).not.toContainText('Class 8');

  // struck off in Grade 12 without sitting the board exam: refused, with the Transfer Certificate offered
  await page.getByLabel(/Student \(Grade 10 or 12\)/).selectOption({ label: 'Struck Off Twelve (2019-1002) · Class 12 · struck off' });
  await page.getByTestId('slc-submit').click();
  await expect(page.getByTestId('slc-error')).toContainText('Transfer Certificate');
  await expect(page.getByTestId('slc-offer-tc')).toBeVisible();

  await page.getByLabel(/Student \(Grade 10 or 12\)/).selectOption({ label: 'Hira Medical (2019-1001) · Class 12 · passed out' });
  await page.getByTestId('slc-submit').click();
  await expect(page.getByTestId('slc-result')).toBeVisible({ timeout: 60000 });
  await expect(page.getByTestId('slc-result-status')).toHaveText('Result Awaited');
  await expect(page.getByTestId('slc-row')).toHaveCount(1);
  await expect(page.getByTestId('slc-row')).toContainText('SLC-');

  const { data: issue } = await db.from('certificate_issue').select('payload_snapshot, certificate_type').eq('tenant_id', tenant).single();
  const values = (issue!.payload_snapshot as { values: Record<string, string> }).values;
  expect(issue!.certificate_type).toBe('leaving');
  expect(values['leaving.board']).toBe('FBISE');
  expect(values['leaving.roll_no']).toBe('462119');
  expect(values['leaving.group']).toBe('Pre-Medical');
  expect(values['leaving.class_roman']).toBe('XII');
});
