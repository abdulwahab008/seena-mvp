import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

test('a librarian scans the shelves and sees which copies are missing', async ({ page }) => {
  const seed = await seedLibraryTenant('stockaudit');
  const { data: title } = await seed.db.from('library_title').insert({ tenant_id: seed.tenant, title: 'Stock Audit Primer' }).select('id').single();
  await seed.db.from('library_copy').insert(
    ['SA-1', 'SA-2', 'SA-3'].map((code, i) => ({ tenant_id: seed.tenant, campus_id: seed.campusId, title_id: title!.id, accession_no: `ACC-${i + 1}`, barcode: code, status: i === 2 ? 'issued' as const : 'available' as const })),
  );
  const librarian = await seed.mk('librarian', 'librarian');
  await signInAs(page, librarian.email);

  await page.goto('/library/stock-audit');
  await page.getByLabel('Scanned barcodes').fill('SA-1\nSA-3\nNOPE-9');
  await page.getByRole('button', { name: 'Compare with register' }).click();
  await expect(page.getByTestId('audit-summary')).toContainText('1 on the shelf as expected · 1 missing · 1 out on the register · 1 unknown codes');
  await expect(page.getByTestId('audit-missing')).toContainText('SA-2');
  await expect(page.getByTestId('audit-out')).toContainText('SA-3');
});
