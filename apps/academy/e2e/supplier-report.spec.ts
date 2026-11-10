import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the supplier report totals what was ordered and what is still to arrive', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, owner } = await seedHrTenant('supplier-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const vendor = await must(db.from('procurement_vendor').insert({ tenant_id, name: 'Chair Traders', phone: '03001234567' }).select('id').single());
  const req = await must(
    db.from('purchase_requisition').insert({ tenant_id, campus_id, req_no: 'REQ-1', justification: 'New chairs', raised_by: owner.userId, est_total: 100000, status: 'converted' }).select('id').single(),
  );
  const po = await must(db.from('purchase_order').insert({ tenant_id, campus_id, po_no: 'PO-1', req_id: req.id, vendor_id: vendor.id, status: 'partially_fulfilled' }).select('id').single());
  await must(db.from('purchase_order_line').insert({ tenant_id, po_id: po.id, description: 'Chair', qty_ordered: 10, unit_cost: 500000 }).select('id').single());

  await signInAs(page, owner.email);
  await page.goto('/purchasing/suppliers');
  const row = page.getByTestId('supplier-row').filter({ hasText: 'Chair Traders' });
  await expect(row).toContainText('PKR 50,000');
  await expect(row.locator('td').nth(3)).toHaveText('1');
});
