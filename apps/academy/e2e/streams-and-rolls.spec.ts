import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('an owner sets the campus exam board, adds a stream and puts a section on it', async ({ page }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(0, 'streams-e2e');
  await signInAs(page, seed.email);

  await page.goto('/academic-setup/streams');
  const board = page.getByTestId('campus-board-form');
  await board.getByLabel('Campus').selectOption({ index: 1 });
  await board.getByLabel('Board').selectOption('PUNJAB');
  await page.getByTestId('campus-board-form-submit').click();
  await expect(page.getByTestId('campus-boards')).toContainText('BISE Punjab');

  const form = page.getByTestId('stream-form');
  await form.getByLabel('Code').fill('SCI');
  await form.getByLabel('Name', { exact: true }).fill('Science');
  await form.getByLabel('Board').selectOption('PUNJAB');
  await form.getByLabel('Starts from class').selectOption({ index: 1 });
  await page.getByTestId('stream-form-submit').click();
  await expect(page.getByTestId('stream-SCI')).toContainText('Science');

  const sec = page.getByTestId('section-stream-form');
  await sec.getByLabel('Section').selectOption({ index: 1 });
  await sec.getByLabel('Stream').selectOption({ label: 'Science' });
  await page.getByTestId('section-stream-form-submit').click();
  await expect.poll(async () => (await seed.db.from('class_section').select('stream_id').eq('tenant_id', seed.tenant).single()).data?.stream_id).toBeTruthy();

  await page.getByTestId('stream-toggle-SCI').click();
  await expect(page.getByTestId('stream-SCI')).toContainText('Inactive');

  const marks = page.getByTestId('mark-precision-form');
  await marks.getByLabel('Campus').selectOption({ index: 1 });
  await marks.getByLabel('Decimal places').selectOption('1');
  await page.getByTestId('mark-precision-form-submit').click();
  await expect(page.getByTestId('campus-rules')).toContainText('marks up to 1 decimal place');

  const hw = page.getByTestId('homework-load-form');
  await hw.getByLabel('Campus').selectOption({ index: 1 });
  await hw.getByLabel('Most assignments a day').fill('3');
  await page.getByTestId('homework-load-form-submit').click();
  await expect(page.getByTestId('campus-rules')).toContainText('at most 3 assignments a day per section');
});

test('a roll number is changed by hand, then the section is renumbered A to Z', async ({ page }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(3, 'rolls-e2e');
  const { data: section } = await seed.db.from('class_section').select('id').eq('tenant_id', seed.tenant).single();
  await signInAs(page, seed.email);

  await page.goto(`/academic-setup/class-reports/class-list?section=${section!.id}`);
  const kid3 = page.getByLabel('Roll number of rolls-e2e Kid 3');
  await kid3.fill('2');
  await kid3.blur();
  await expect(page.getByText('Roll 2 is already taken in this section.')).toBeVisible();
  await kid3.fill('9');
  await kid3.blur();
  await expect(page.getByText('Roll number saved.')).toBeVisible();
  // Let the saved roll's page refresh land before the next action, so a late refresh cannot overwrite the renumbering.
  await page.waitForLoadState('networkidle');
  await expect(page.getByLabel('Roll number of rolls-e2e Kid 3')).toHaveValue('9');

  page.once('dialog', (d) => d.accept());
  await page.getByTestId('renumber-rolls').click();
  await expect(page.getByText('Renumbered 3 students A to Z.')).toBeVisible();
  await expect(page.getByLabel('Roll number of rolls-e2e Kid 3')).toHaveValue('3');
  await expect(page.getByLabel('Roll number of rolls-e2e Kid 1')).toHaveValue('1');
});
