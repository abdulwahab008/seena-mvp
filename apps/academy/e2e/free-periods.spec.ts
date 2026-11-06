import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('free teachers and rooms leave out whoever is booked in that period', async ({ page }) => {
  const { db, tenantId, campusId, mkUser, owner } = await seedHrTenant('freeperiods');
  const busy = await mkUser('busy', 'subject_teacher');
  const idle = await mkUser('idle', 'subject_teacher');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenantId).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenantId).eq('code', '1').single();
  const { data: section } = await db.from('class_section').insert({ tenant_id: tenantId, campus_id: campusId, session_id: session!.id, class_level_id: level!.id, name: 'A', capacity: 30 }).select('id').single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenantId, code: 'ENG', name_en: 'English', name_ur: 'انگریزی' }).select('id').single();
  const { data: rooms } = await db.from('room').insert([
    { tenant_id: tenantId, campus_id: campusId, code: 'R1', name: 'Room One', capacity: 30 },
    { tenant_id: tenantId, campus_id: campusId, code: 'R2', name: 'Room Two', capacity: 30 },
  ]).select('id, code');
  const { data: version } = await db.from('timetable_version').insert({ tenant_id: tenantId, campus_id: campusId, session_id: session!.id, shift: 'MORNING', name: 'Term 1', version_no: 1 }).select('id').single();
  const { error } = await db.from('timetable_slot').insert({
    tenant_id: tenantId, campus_id: campusId, timetable_version_id: version!.id, section_id: section!.id, weekday: 1, period_no: 2,
    subject_id: subject!.id, staff_id: busy.userId, room_id: rooms!.find((r) => r.code === 'R1')!.id,
  });
  if (error) throw error;
  const { error: pubError } = await db.from('timetable_version').update({ status: 'PUBLISHED', published_at: new Date().toISOString() }).eq('id', version!.id);
  if (pubError) throw pubError;

  await signInAs(page, owner.email);
  await page.goto('/academic-setup/free-periods?day=1&period=2');
  await expect(page.getByTestId('free-teachers')).toContainText(idle.fullName);
  await expect(page.getByTestId('free-teachers')).not.toContainText(busy.fullName);
  await expect(page.getByTestId('free-rooms')).toContainText('R2');
  await expect(page.getByTestId('free-rooms')).not.toContainText('R1 ·');
});
