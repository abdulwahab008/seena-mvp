import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

// FR-O02: a librarian registers copies with unique accession numbers and barcodes, a bulk import with duplicate
// barcodes fails atomically and names the offending rows, and the title shows "x of y available".

test('copies are registered with unique accession numbers; a bad CSV import changes nothing', async ({ page }) => {
  test.setTimeout(120000);
  const { db, tenant, mk } = await seedLibraryTenant('libcopy-e2e');
  const librarian = await mk('librarian', 'librarian');
  const { data: title } = await db.from('library_title').insert({ tenant_id: tenant, title: 'Physics 9', title_ur: 'طبیعیات' }).select('id').single();
  await signInAs(page, librarian.email);

  await page.goto(`/library/copies?title=${title!.id}`);
  await page.getByLabel('Accession number').fill('LIB-2026-00431');
  await page.getByLabel('Barcode').fill('BC-431');
  await page.getByTestId('register-copy').click();
  await expect(page.getByTestId('copy-row')).toHaveCount(1);
  await expect(page.getByTestId('availability')).toContainText('1 of 1 available');

  // the same accession number again is refused
  await page.getByLabel('Accession number').fill('LIB-2026-00431');
  await page.getByLabel('Barcode').fill('BC-NEW');
  await page.getByTestId('register-copy').click();
  await expect(page.getByTestId('copy-error')).toContainText('accession number is already used');

  // an import with two duplicate barcodes fails as a whole
  const csv = ['accession_no,barcode,title_id', `A1,B1,${title!.id}`, `A2,B2,${title!.id}`, `A3,B1,${title!.id}`, `A4,BC-431,${title!.id}`].join('\n');
  await page.getByLabel('Copies CSV').setInputFiles({ name: 'copies.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await page.getByTestId('import-copies').click();
  await expect(page.getByTestId('import-problems')).toContainText('Row 3');
  await expect(page.getByTestId('import-problems')).toContainText('Row 4');
  await expect(page.getByTestId('import-problems')).toContainText('Nothing was imported');
  const { count } = await db.from('library_copy').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant);
  expect(count).toBe(1);

  // a clean import commits
  const good = ['accession_no,barcode,title_id', `A1,B1,${title!.id}`, `A2,B2,${title!.id}`].join('\n');
  await page.getByLabel('Copies CSV').setInputFiles({ name: 'good.csv', mimeType: 'text/csv', buffer: Buffer.from(good) });
  await page.getByTestId('import-copies').click();
  await expect(page.getByTestId('copy-row')).toHaveCount(3);
  await expect(page.getByTestId('availability')).toContainText('3 of 3 available');
});
