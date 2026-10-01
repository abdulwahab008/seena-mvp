import { test, expect, request as playwrightRequest } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';

// FR-T10: scanning the QR on a certificate, with no login. Valid, cancelled, unknown and rate limited.

test('public verification: valid, cancelled, unknown token and the per-address limit', async ({ baseURL }) => {
  test.setTimeout(180000);
  const { db, owner$, tenant, campusId } = await seedFeesTenant(0, 'verify-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '12').single();
  const { data: section } = await db.from('class_section').insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, class_level_id: level!.id, name: 'A', capacity: 30 }).select('id').single();
  const { data: student } = await db
    .from('student')
    .insert({ tenant_id: tenant, campus_id: campusId, gr_number: '2019-0311', name_en: 'Ahmed Hassan', father_name_en: 'Hassan Ali', dob: '2008-01-01', gender: 'male', status: 'passed_out' })
    .select('id')
    .single();
  const { data: enrolment } = await db
    .from('enrolment')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, student_id: student!.id, class_level_id: level!.id, section_id: section!.id, status: 'graduated', joined_on: '2024-04-01' })
    .select('id')
    .single();
  await db.from('exam_registration').insert({ tenant_id: tenant, campus_id: campusId, student_id: student!.id, enrolment_id: enrolment!.id, board_code: 'FBISE', roll_no: '462119', group_code: 'Pre-Medical' });
  const { data: templateId } = await owner$.rpc('create_certificate_template', {
    p_certificate_type: 'leaving',
    p_title: 'School Leaving Certificate',
    p_body_html: '<p>{{student.name_en}} {{student.gr_number}} {{leaving.board}} {{leaving.class_roman}} {{leaving.result_status}} {{issue.serial_no}} {{issue.date}}</p>',
    p_language: 'en',
    p_page_size: 'A4',
    p_campus_id: campusId,
  });
  await owner$.rpc('activate_certificate_template', { p_template_id: templateId as string });
  const { data: issued, error } = await owner$.rpc('issue_leaving_certificate', { p_enrolment_id: enrolment!.id });
  expect(error).toBeNull();
  const issue = issued as unknown as { issue_id: string; serial_no: string };
  const { data: row } = await db.from('certificate_issue').select('verify_token').eq('id', issue.issue_id).single();
  const token = row!.verify_token;

  // no cookies, no session: a fresh context
  const anon = await playwrightRequest.newContext({ baseURL: baseURL ?? 'http://localhost:3000' });
  const ip = (n: number) => ({ 'x-forwarded-for': `198.51.100.${n}` });

  const valid = await anon.get(`/verify/${token}`, { headers: ip(1) });
  expect(valid.status()).toBe(200);
  const validHtml = await valid.text();
  expect(validHtml).toContain(`VALID - School Leaving Certificate ${issue.serial_no}`);
  expect(validHtml).toContain('to A* H (GR 2019-)');
  expect(validHtml).not.toContain('Ahmed');
  expect(validHtml).not.toContain('0311');
  expect(validHtml).not.toContain('Hassan');

  const unknown = await anon.get('/verify/not-a-real-token-at-all', { headers: ip(2) });
  expect(unknown.status()).toBe(404);
  expect(await unknown.text()).toContain('No certificate found for this code');

  // hit and miss take the same time
  const time = async (path: string, n: number) => {
    const samples: number[] = [];
    for (let i = 0; i < 5; i++) {
      const t0 = Date.now();
      await anon.get(path, { headers: ip(10 + n * 10 + i) });
      samples.push(Date.now() - t0);
    }
    return samples.sort((a, b) => a - b)[2]!;
  };
  const hit = await time(`/verify/${token}`, 1);
  const miss = await time('/verify/zzzzzzzzzzzzzzzzzzzzzzzz', 2);
  expect(Math.abs(hit - miss)).toBeLessThan(50);

  // cancelled: red, dated, and no student details
  const { error: revokeError } = await owner$.rpc('revoke_certificate', { p_issue_id: issue.issue_id, p_reason: 'Issued in error' });
  expect(revokeError).toBeNull();
  const cancelled = await anon.get(`/verify/${token}`, { headers: ip(3) });
  expect(cancelled.status()).toBe(200);
  const cancelledHtml = await cancelled.text();
  expect(cancelledHtml).toMatch(/CANCELLED on \d{2}-[A-Z][a-z]{2}-\d{4}/);
  expect(cancelledHtml).toContain('data-state="cancelled"');
  expect(cancelledHtml).not.toContain('Ahmed');

  // 60 a minute per address
  const statuses: number[] = [];
  for (let i = 0; i < 65; i++) statuses.push((await anon.get('/verify/not-a-real-token-at-all', { headers: ip(200) })).status());
  expect(statuses.filter((s) => s === 429).length).toBeGreaterThanOrEqual(5);
  expect(statuses.slice(0, 60).every((s) => s === 404)).toBe(true);
  await anon.dispose();
});
