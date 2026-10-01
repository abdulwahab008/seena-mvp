import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

// FR-O01: a librarian catalogues titles once per ISBN; the hyphenated form of an existing ISBN is refused,
// titles without an ISBN never conflict, and the Urdu title is searchable.

test('a librarian catalogues titles, duplicate ISBNs are refused, Urdu search finds the title', async ({ page }) => {
  test.setTimeout(120000);
  const { mk } = await seedLibraryTenant('libtitle-e2e');
  const librarian = await mk('librarian', 'librarian');
  await signInAs(page, librarian.email);

  const add = async (title: string, isbn: string, titleUr = '') => {
    await page.goto('/library/titles');
    await page.getByLabel('Title', { exact: true }).fill(title);
    await page.getByLabel('Title (Urdu)').fill(titleUr);
    await page.getByLabel('ISBN (optional)').fill(isbn);
    await page.getByTestId('save-title').click();
  };

  await add('Pakistan Studies 9', '9789693526011', 'معاشرتی علوم');
  await page.goto('/library/titles');
  await expect(page.getByTestId('title-row')).toHaveCount(1);
  await expect(page.getByTestId('title-row')).toContainText('ISBN 9789693526011');

  await add('Pakistan Studies 9 reprint', '978-969-352-601-1');
  await expect(page.getByTestId('title-error')).toContainText('already in the catalogue');

  await add('Islamiyat Notes', '', 'اسلامیات نوٹس');
  await add('Islamiyat Guide', '', 'اسلامیات گائیڈ');
  await page.goto('/library/titles');
  await expect(page.getByTestId('title-row')).toHaveCount(3);

  await page.getByTestId('title-search').fill('معاشرتی علوم');
  await page.getByRole('button', { name: 'Search' }).click();
  await expect(page.getByTestId('title-row')).toHaveCount(1);
  await expect(page.getByTestId('title-row')).toContainText('Pakistan Studies 9');
});
