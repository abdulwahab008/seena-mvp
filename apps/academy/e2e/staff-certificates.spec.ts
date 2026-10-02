import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs, userClient } from './support/hr-seed';
import { resolveNastaliqFont } from '../lib/pdf/font';

// FR-D18: HR issues a numbered experience certificate; the PDF carries the embedded Nastaliq face for the Urdu
// school name and is served identically on reprint (no new number); an open termination blocks HR and only
// the Owner, with a reason, can release it.

// The Noto Nastaliq Urdu face is not committed to the repo; the render host supplies it (lib/pdf/font.ts). Without it
// the certificate still renders, with a fallback face, so only the embedded-face assertion depends on the font.
const nastaliqInstalled = resolveNastaliqFont() !== null;

function pdfBaseFonts(body: Buffer): string[] {
  return [...body.toString('latin1').matchAll(/\/BaseFont\s*\/([A-Za-z0-9+,.\-_]+)/g)].map((m) => m[1]!.replace(/^[A-Z]{6}\+/, ''));
}

test('a certificate is numbered once, prints with Nastaliq, reprints identically and respects the misconduct block', async ({ page, browser, baseURL }) => {
  test.setTimeout(180000);
  const { db, tenantId, campusId, mkUser, owner } = await seedHrTenant('cert-e2e');
  await db.from('tenant').update({ name_ur: 'برائٹ فیوچر اسکول' }).eq('id', tenantId);
  const hr = await mkUser('hrmanager', 'hr_manager');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: { doj: '2019-04-01' } });
  await db.from('staff_exit').insert({ tenant_id: tenantId, campus_id: campusId, staff_id: teacher.staffId, exit_type: 'retirement', last_working_date: '2026-08-31' });

  await signInAs(page, hr.email);
  await page.goto('/staff/certificates');
  await page.getByLabel('Staff member').selectOption(teacher.staffId!);
  await page.getByLabel('Certificate', { exact: true }).selectOption('experience');
  await page.getByTestId('issue-certificate').click();
  await expect(page.getByTestId('certificate-row')).toHaveCount(1);
  await expect(page.getByTestId('certificate-row')).toContainText(`EXP-${new Date().getFullYear()}-0001`);

  const { data: cert } = await db.from('staff_certificate').select('id, payload').eq('tenant_id', tenantId).single();
  expect((cert!.payload as { total_service: string }).total_service).toBe('7 years 5 months');

  const first = await page.request.get(`/api/staff-certificates/${cert!.id}/pdf`);
  expect(first.status()).toBe(200);
  const body = Buffer.from(await first.body());
  expect(body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  if (nastaliqInstalled) {
    // Builds of the font differ on whether the PostScript name carries a "-Regular" suffix; the family is what matters.
    expect(pdfBaseFonts(body).map((n) => n.replace(/-Regular$/, ''))).toContain('NotoNastaliqUrdu');
  } else {
    test.info().annotations.push({ type: 'skipped-assertion', description: 'Embedded Nastaliq face not asserted: Noto Nastaliq Urdu is not installed on this host (set ACADEMY_NASTALIQ_FONT_PATH).' });
  }
  expect(first.headers()['x-pdf-source']).toBe('rendered');
  const again = await page.request.get(`/api/staff-certificates/${cert!.id}/pdf`);
  expect(again.headers()['x-pdf-source']).toBe('served');
  expect(again.headers()['x-pdf-sha256']).toBe(first.headers()['x-pdf-sha256']);
  const { data: counter } = await db.from('staff_certificate_counter').select('last_value').eq('tenant_id', tenantId).eq('cert_type', 'experience').single();
  expect(counter!.last_value).toBe(1);

  // An open termination for misconduct blocks HR; the Owner can release it with a reason.
  const hr$ = await userClient(hr.email);
  const { error: termErr } = await hr$.rpc('issue_disciplinary_action', { p_staff_id: teacher.staffId!, p_action_type: 'termination', p_description: 'Gross misconduct' });
  expect(termErr).toBeNull();
  await page.goto('/staff/certificates');
  await page.getByLabel('Staff member').selectOption(teacher.staffId!);
  await page.getByLabel('Certificate', { exact: true }).selectOption('experience');
  await page.getByTestId('issue-certificate').click();
  await expect(page.getByTestId('certificate-error')).toContainText('only be released by the Owner');

  const octx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const op = await octx.newPage();
  await signInAs(op, owner.email);
  await op.goto('/staff/certificates');
  await op.getByLabel('Staff member').selectOption(teacher.staffId!);
  await op.getByLabel('Certificate', { exact: true }).selectOption('experience');
  await op.getByLabel(/Owner override reason/).fill('Board inquiry cleared; owner approves release');
  await op.getByTestId('issue-certificate').click();
  await expect(op.getByTestId('certificate-row')).toHaveCount(2);
  await expect(op.getByTestId('certificate-list')).toContainText('Owner override');
  await octx.close();
});
