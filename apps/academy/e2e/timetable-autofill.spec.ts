import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the timetable fills a section automatically and copies it to another section', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, owner, runId } = await seedHrTenant('tt-autofill');
  const one = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>) => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const session = await one(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await one(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '1').single());
  const base = { tenant_id, campus_id, session_id: session.id, class_level_id: level.id, capacity: 30 };
  const secA = await one(db.from('class_section').insert({ ...base, name: 'A' }).select('id').single());
  await one(db.from('class_section').insert({ ...base, name: 'B' }).select('id').single());
  const chem = await one(db.from('subject').insert({ tenant_id, code: `CH${runId}`.slice(0, 10), name_en: 'Chemistry' }).select('id').single());
  await one(db.from('class_subject').insert({ tenant_id, campus_id, session_id: session.id, class_level_id: level.id, subject_id: chem.id, weekly_periods: 3 }).select('id').single());
  const bell = await one(db.from('bell_template').insert({ tenant_id, campus_id, shift: 'MORNING', code: 'STD', name: 'Standard', is_default: true }).select('id').single());
  await db.from('bell_period').insert([1, 2, 3, 4].map((n) => ({ bell_template_id: bell.id, segment_ordinal: n, period_no: n, kind: 'TEACHING', start_time: `0${7 + n}:00`.slice(-5), end_time: `0${7 + n}:40`.slice(-5) })));
  const version = await one(db.from('timetable_version').insert({ tenant_id, campus_id, session_id: session.id, shift: 'MORNING', name: 'Draft', version_no: 1 }).select('id').single());

  await signInAs(page, owner.email);
  await page.goto(`/academic-setup/timetable?version=${version.id}&section=${secA.id}`);
  await page.getByRole('button', { name: 'Fill empty periods automatically' }).click();
  await expect(page.getByText('Placed 3 periods.')).toBeVisible();

  const { data: sections } = await db.from('class_section').select('id, name').eq('campus_id', campus_id);
  const secB = sections!.find((s) => s.name === 'B')!;
  await page.goto(`/academic-setup/timetable?version=${version.id}&section=${secB.id}`);
  await page.getByLabel('Copy from section').selectOption(secA.id);
  await page.getByRole('button', { name: 'Copy', exact: true }).click();
  await expect(page.getByText('Copied 3 periods.')).toBeVisible();
});
