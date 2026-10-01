import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

// FR-D20: a teacher timetabled for 34 periods against 30 contracted shows +4 and over-loaded, the 3 periods they
// covered for a colleague appear in their own column, and the XLSX export has a header row plus one row per teacher.

const mondayOfThisWeek = () => {
  const d = new Date(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' }) + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
};
const addDays = (iso: string, n: number) => new Date(new Date(iso + 'T00:00:00Z').getTime() + n * 86_400_000).toISOString().slice(0, 10);

test('the workload report shows variance, separates substitution, and exports one row per teacher', async ({ page }) => {
  test.setTimeout(120000);
  const { db, tenantId, campusId, mkUser } = await seedHrTenant('wl-e2e');
  const principal = await mkUser('principal', 'principal');
  const a = await mkUser('teachera', 'subject_teacher', { staff: {} });
  const b = await mkUser('teacherb', 'subject_teacher', { staff: {} });
  const monday = mondayOfThisWeek();

  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenantId).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenantId).eq('code', '1').single();
  const { data: secs } = await db
    .from('class_section')
    .insert([
      { tenant_id: tenantId, campus_id: campusId, session_id: session!.id, class_level_id: level!.id, name: 'A', capacity: 30 },
      { tenant_id: tenantId, campus_id: campusId, session_id: session!.id, class_level_id: level!.id, name: 'B', capacity: 30 },
    ])
    .select('id, name');
  const secA = secs!.find((s) => s.name === 'A')!.id;
  const secB = secs!.find((s) => s.name === 'B')!.id;
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenantId, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { data: version } = await db
    .from('timetable_version')
    .insert({ tenant_id: tenantId, campus_id: campusId, session_id: session!.id, shift: 'MORNING', name: 'v1', status: 'PUBLISHED', version_no: 1, effective_from: addDays(monday, -60), effective_to: addDays(monday, 90), published_at: new Date().toISOString() })
    .select('id')
    .single();
  await db.from('staff_contract').insert({ tenant_id: tenantId, staff_id: a.staffId, contract_type: 'permanent', start_date: addDays(monday, -200), contracted_periods_per_week: 30 });

  const slots: Record<string, unknown>[] = [];
  for (let d = 1; d <= 5; d++) for (let p = 1; p <= 7; p++) if (!(d === 5 && p === 7)) slots.push({ tenant_id: tenantId, campus_id: campusId, timetable_version_id: version!.id, section_id: secA, weekday: d, period_no: p, subject_id: subject!.id, staff_id: a.userId });
  for (let p = 1; p <= 5; p++) slots.push({ tenant_id: tenantId, campus_id: campusId, timetable_version_id: version!.id, section_id: secB, weekday: 1, period_no: p, subject_id: subject!.id, staff_id: b.userId });
  const { error: slotErr } = await db.from('timetable_slot').insert(slots);
  expect(slotErr).toBeNull();
  const { data: bSlots } = await db.from('timetable_slot').select('id').eq('section_id', secB).lte('period_no', 3);
  await db.from('timetable_substitution').insert(
    bSlots!.map((s) => ({ tenant_id: tenantId, campus_id: campusId, slot_id: s.id, sub_date: monday, absent_staff_id: b.userId, substitute_staff_id: a.userId, reason: 'other', status: 'active' })),
  );

  await signInAs(page, principal.email);
  await page.goto('/staff/workload');
  await page.getByTestId('refresh-workload').click();
  const rowA = page.getByTestId(`workload-row-${(await db.from('staff').select('employee_code').eq('id', a.staffId!).single()).data!.employee_code}`);
  await expect(rowA.getByTestId('variance')).toHaveText('+4');
  await expect(rowA.getByTestId('substituted')).toHaveText('3');
  await expect(rowA).toContainText('Over-loaded');

  const week = (await page.getByTestId('workload-week').textContent())!.split(' ')[0]!;
  const xlsx = await page.request.get(`/api/reports/teacher-workload?campus=${campusId}&week=${week}`);
  expect(xlsx.status()).toBe(200);
  expect(xlsx.headers()['content-type']).toContain('spreadsheetml');
  const rows = Buffer.from(await xlsx.body()).toString('utf8').match(/<row r="/g) ?? [];
  expect(rows.length).toBe(1 + 2); // header + teachers A and B
});
