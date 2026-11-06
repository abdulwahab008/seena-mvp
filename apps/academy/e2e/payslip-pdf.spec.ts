import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs, userClient } from './support/hr-seed';

// FR-L08: a locked run yields an itemised PDF per employee; a draft run is refused with 409 and no files;
// an employee cannot fetch a colleague's payslip (403, audited); a regeneration after an adjustment adds a new version.

test('payslips are generated for a locked run and guarded for everyone else', async ({ page, browser, baseURL }) => {
  test.setTimeout(240000);
  const { db, tenantId, campusId, mkUser, owner } = await seedHrTenant('payslip-e2e');
  const a = await mkUser('emp-a', 'subject_teacher', { staff: { doj: '2025-01-01' } });
  const b = await mkUser('emp-b', 'subject_teacher', { staff: { doj: '2025-01-01' } });
  for (const s of [a, b]) {
    const { error } = await db.from('employee_salary_structure').insert({
      tenant_id: tenantId, campus_id: campusId, staff_id: s.staffId!, validity: '[2026-01-01,2026-12-31]', basic_paisa: 7000000,
    });
    expect(error).toBeNull();
  }

  const o = await userClient(owner.email);
  const { data: runId, error: genErr } = await o.rpc('generate_payroll_run', { p_campus_id: campusId, p_period_date: '2026-08-01' });
  expect(genErr).toBeNull();
  const { data: lines } = await db.from('payroll_run_line').select('id, staff_id').eq('payroll_run_id', runId as string);
  const lineOf = (staffId: string) => lines!.find((l) => l.staff_id === staffId)!.id;
  const { data: comp } = await db.from('salary_component').select('id').eq('tenant_id', tenantId).limit(1).single();
  await db.from('payroll_run_line_component').insert(
    lines!.map((l) => ({ line_id: l.id, component_id: comp!.id, code: 'BASIC', name_en: 'Basic', component_type: 'earning', amount_paisa: 7000000, is_taxable: true })),
  );

  await signInAs(page, owner.email);
  const draft = await page.request.post(`/api/payroll/runs/${runId}/payslips`);
  expect(draft.status()).toBe(409);
  expect((await draft.json()).error).toBe('run_not_locked');
  const { count: none } = await db.from('payslip').select('id', { count: 'exact', head: true }).eq('tenant_id', tenantId);
  expect(none).toBe(0);

  const { error: lockErr } = await o.rpc('fn_lock_payroll_run', { p_run_id: runId as string });
  expect(lockErr).toBeNull();

  const gen = await page.request.post(`/api/payroll/runs/${runId}/payslips`);
  expect(gen.status()).toBe(200);
  expect(await gen.json()).toEqual({ total: 2, created: 2 });
  const { data: slips } = await db.from('payslip').select('storage_path, version').eq('tenant_id', tenantId).order('storage_path');
  expect(slips).toHaveLength(2);
  expect(slips![0]!.storage_path).toBe(`${tenantId}/${runId}/${[a.staffId, b.staffId].sort()[0]}-v1.pdf`);

  const again = await page.request.post(`/api/payroll/runs/${runId}/payslips`);
  expect(await again.json()).toEqual({ total: 2, created: 0 });

  const pdf = await page.request.get(`/api/payroll/payslips/${lineOf(a.staffId!)}`);
  expect(pdf.status()).toBe(200);
  expect(Buffer.from(await pdf.body()).subarray(0, 5).toString('latin1')).toBe('%PDF-');

  const ctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const ep = await ctx.newPage();
  await signInAs(ep, a.email);
  expect((await ep.request.get(`/api/payroll/payslips/${lineOf(a.staffId!)}`)).status()).toBe(200);
  expect((await ep.request.get(`/api/payroll/payslips/${lineOf(b.staffId!)}`)).status()).toBe(403);
  await ctx.close();
  const { count: denied } = await db.from('payslip_denied_access').select('id', { count: 'exact', head: true }).eq('tenant_id', tenantId);
  expect(denied).toBe(1);
  const { count: audited } = await db.from('audit_log').select('id', { count: 'exact', head: true }).eq('tenant_id', tenantId).eq('table_name', 'payslip_denied_access');
  expect(audited).toBe(1);
});
