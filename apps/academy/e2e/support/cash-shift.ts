import { expect, type Page } from '@playwright/test';

// Cash is only taken against an open counter shift (FR-K18 and the admission-fee rule). For an
// owner on a fresh school: add a counter if there is none, then open a shift on it.
export async function openCashShift(page: Page, counterName = 'Front desk') {
  await page.goto('/fees/counter');
  await page.waitForLoadState('networkidle');
  if (await page.getByTestId('open-session-label').isVisible()) return;
  if (!(await page.getByTestId('open-counter').isVisible())) {
    await page.locator('#ctrName').fill(counterName);
    await page.getByTestId('create-counter').click();
    await expect(page.getByText('Counter added.')).toBeVisible();
    await page.reload();
    await page.waitForLoadState('networkidle');
  }
  await page.getByTestId('open-counter').click();
  await expect(page.getByTestId('open-session-label')).toBeVisible();
}
