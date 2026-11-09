import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('student documents lists what can be issued and links to each issue page', async ({ page }) => {
  const { owner } = await seedHrTenant('student-docs-e2e');
  await signInAs(page, owner.email);
  await page.goto('/students/documents');
  await expect(page.getByTestId('document-row')).toHaveCount(6);
  await expect(page.getByText('No documents issued yet.')).toBeVisible();
  await page.getByTestId('document-row').filter({ hasText: 'Character certificate' }).getByRole('link', { name: 'Issue' }).click();
  await expect(page).toHaveURL(/\/certificates\/issue\/character$/);
});
