import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H02: type sniffing, size and count limits, signed-URL redirect, and object cleanup on delete.

const SECRET = process.env.EXPORT_WORKER_SECRET!;
const pdf = (size = 2000) => Buffer.concat([Buffer.from('%PDF-1.4\n'), Buffer.alloc(size, 0x20)]);

test('a teacher attaches files within limits and deleting the assignment removes the objects', async ({ page, request }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'hwatt-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'SCI', name_en: 'Science', name_ur: 'سائنس' }).select('id').single();
  const { data: auth } = await owner$.auth.getUser();
  const { data: hw, error } = await db
    .from('homework')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, section_id: section!.id, subject_id: subject!.id, teacher_id: auth.user!.id, title: 'Attach E2E', due_date: new Date(Date.now() + 3 * 86400000).toISOString().slice(0, 10), status: 'published', published_at: new Date().toISOString() })
    .select('id')
    .single();
  expect(error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
  await page.goto('/homework');

  const attach = (name: string, mimeType: string, buffer: Buffer) => page.getByLabel('Attach a file').setInputFiles({ name, mimeType, buffer });

  await attach('worksheet.pdf', 'application/pdf', pdf());
  await expect(page.getByTestId('homework-attachment')).toHaveCount(1);

  await attach('virus.pdf', 'application/pdf', Buffer.concat([Buffer.from([0x4d, 0x5a, 0x90, 0x00]), Buffer.alloc(500, 1)]));
  await expect(page.getByTestId('attachment-error')).toHaveText('Only PDF, JPEG, PNG or WebP files can be attached');
  await expect(page.getByTestId('homework-attachment')).toHaveCount(1);

  await attach('huge.pdf', 'application/pdf', pdf(6 * 1024 * 1024));
  await expect(page.getByTestId('attachment-error')).toHaveText('File exceeds 5 MB limit');

  for (let i = 2; i <= 5; i++) {
    await attach(`sheet-${i}.pdf`, 'application/pdf', pdf(1000 + i));
    await expect(page.getByTestId('homework-attachment')).toHaveCount(i);
  }
  await attach('sixth.pdf', 'application/pdf', pdf(1006));
  await expect(page.getByTestId('attachment-error')).toHaveText('Maximum 5 attachments per assignment');

  const { data: rows } = await db.from('homework_attachment').select('id, storage_path').eq('homework_id', hw!.id);
  expect(rows).toHaveLength(5);
  expect(rows![0]!.storage_path.startsWith(`${tenant}/${campusId}/${session!.id}/${hw!.id}/`)).toBe(true);
  const link = await page.request.get(`/api/homework-attachments/${rows![0]!.id}`, { maxRedirects: 0 });
  expect(link.status()).toBe(302);
  expect(link.headers().location).toContain('/storage/v1/object/sign/homework-attachments/');

  const { data: before } = await db.storage.from('homework-attachments').list(`${tenant}/${campusId}/${session!.id}/${hw!.id}`);
  expect(before).toHaveLength(5);

  await page.getByTestId('homework-delete').click();
  await expect(page.getByText('Attach E2E')).toHaveCount(0);
  await expect
    .poll(
      async () => {
        await request.post('/api/internal/storage/purge', { headers: { 'x-worker-secret': SECRET } });
        const { data } = await db.storage.from('homework-attachments').list(`${tenant}/${campusId}/${session!.id}/${hw!.id}`);
        return data?.length ?? 0;
      },
      { timeout: 60000 },
    )
    .toBe(0);
});
