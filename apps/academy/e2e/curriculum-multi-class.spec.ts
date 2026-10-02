import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { seedFreshOwner } from './fixtures/fresh-owner';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';

test('curriculum mapping: single-class one-by-one mapping and bulk multi-class assignment & copy', async ({ page }, testInfo) => {
  // 1. Log in as School Owner
  const owner = await seedFreshOwner('curriculum-e2e');

  // provision_tenant seeds class levels but no subjects; the original run
  // relied on English and Mathematics already existing in a long-lived dev
  // tenant. Subjects are the input of this feature, so seed them.
  const admin = createClient(SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
  const { error: subjectError } = await admin.from('subject').insert([
    { tenant_id: owner.tenantId, code: 'ENG', name_en: 'English', name_ur: 'انگریزی' },
    { tenant_id: owner.tenantId, code: 'MTH', name_en: 'Mathematics', name_ur: 'ریاضی' },
  ]);
  if (subjectError) throw subjectError;

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(owner.email);
  await page.getByLabel('Password').fill(owner.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('**/dashboard', { timeout: 15000 });

  // 2. Navigate to Curriculum Mapping
  await page.goto('/academic-setup/curriculum');
  await page.waitForLoadState('networkidle');

  // Verify class selector and switch to Class 1
  await page.getByTestId('curriculum-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.waitForTimeout(300);

  // Capture screenshot of single-class view
  await page.screenshot({
    path: testInfo.outputPath('curriculum_full_page_view.png'),
    fullPage: true,
  });

  // 3. Map a subject (English, 6 periods) to Class 1 AND simultaneously to Classes 2, 3, 4, 5
  await page.getByTestId('curriculum-subject-trigger').click();
  await page.getByRole('option', { name: 'English', exact: true }).click();
  await page.getByLabel('Weekly Periods *').fill('6');

  // Open "Also assign this subject to other classes"
  const multiToggle = page.getByRole('button', { name: /Also assign this subject to other classes/i });
  await multiToggle.click();

  // Click Class 2, Class 3, Class 4, Class 5 buttons
  for (const className of ['Class 2', 'Class 3', 'Class 4', 'Class 5']) {
    await page.getByRole('button', { name: className, exact: true }).click();
  }

  // Click "Map subject"
  await page.getByRole('button', { name: 'Map subject' }).click();
  await expect(page.getByText(/Assigned English to/i)).toBeVisible();

  // Verify English appears in Class 1 table
  const rowEnglish = page.getByTestId('curriculum-row-English');
  await expect(rowEnglish).toBeVisible();

  // 4. Map Mathematics to Class 1 as a single subject
  await page.getByTestId('curriculum-subject-trigger').click();
  await page.getByRole('option', { name: 'Mathematics', exact: true }).click();
  await page.getByLabel('Weekly Periods *').fill('6');
  await page.getByRole('button', { name: 'Map subject' }).click();

  await expect(page.getByText('Mathematics mapped.')).toBeVisible();
  await expect(page.getByTestId('curriculum-row-Mathematics')).toBeVisible();

  // 5. Test "Copy Curriculum Across Classes..." modal
  const copyBtn = page.getByRole('button', { name: /Copy Curriculum Across Classes/i });
  await expect(copyBtn).toBeVisible();
  await copyBtn.click();

  // Verify modal is open
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByText('Copy Curriculum from Class 1')).toBeVisible();
  await page.waitForTimeout(250);

  // Capture screenshot of Copy Curriculum Modal
  await page.screenshot({
    path: testInfo.outputPath('curriculum_copy_modal.png'),
  });

  // Click quick filter "Classes 1–5" (selects Classes 2, 3, 4, 5)
  await page.getByRole('button', { name: 'Classes 1–5' }).click();

  // Click Copy to Selected Classes
  await page.getByRole('button', { name: /Copy to \d+ Classes/i }).click();

  // Verify success toast
  await expect(page.getByText(/Curriculum copied to/i)).toBeVisible();

  // 6. Switch to Class 5 and verify it has both English and Mathematics copied!
  await page.getByTestId('curriculum-class-trigger').click();
  await page.getByRole('option', { name: 'Class 5', exact: true }).click();
  await page.waitForTimeout(400);

  await expect(page.getByTestId('curriculum-row-English')).toBeVisible();
  await expect(page.getByTestId('curriculum-row-Mathematics')).toBeVisible();

  // Capture screenshot of Class 5 with copied curriculum
  await page.screenshot({
    path: testInfo.outputPath('curriculum_multi_class_assigned.png'),
  });
});
