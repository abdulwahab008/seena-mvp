import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('students absent several school days in a row are listed', async ({ page }) => {
  const seed = await seedFeesTenant(1, 'absentees');
  const { data: e } = await seed.db.from('enrolment').select('id, session_id, section_id').eq('campus_id', seed.campusId).single();
  const days = [1, 2, 3, 4].map((d) => new Date(Date.now() - d * 86_400_000).toISOString().slice(0, 10));
  const { error } = await seed.db.from('attendance_day').insert(
    days.map((attendance_date) => ({ tenant_id: seed.tenant, campus_id: seed.campusId, session_id: e!.session_id, section_id: e!.section_id, enrolment_id: e!.id, attendance_date, status: 'absent' as const })),
  );
  if (error) throw error;

  await signInAs(page, seed.email);
  await page.goto('/attendance/shortage');
  await expect(page.getByTestId('absentee-row')).toHaveCount(1);
  await expect(page.getByTestId('absentee-row')).toContainText('4 days');
});
