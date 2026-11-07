import { describe, expect, it } from 'vitest';
import { summarizeSales } from './sales-report';

describe('summarizeSales', () => {
  it('totals sales by item and settlement, netting off credit notes', () => {
    const s = summarizeSales([
      { doc_type: 'sale', settlement: 'cash', total: 300, lines: [{ item: 'Shirt', qty: 2, amount: 240 }, { item: 'Book', qty: 1, amount: 60 }] },
      { doc_type: 'sale', settlement: 'fee_ledger', total: 120, lines: [{ item: 'Shirt', qty: 1, amount: 120 }] },
      { doc_type: 'credit_note', settlement: 'cash', total: 120, lines: [{ item: 'Shirt', qty: 1, amount: 120 }] },
    ]);
    expect(s).toMatchObject({ receipts: 2, creditNotes: 1, net: 300, cash: 180, feeLedger: 120 });
    expect(s.items).toEqual([
      { item: 'Shirt', qty: 2, amount: 240 },
      { item: 'Book', qty: 1, amount: 60 },
    ]);
  });
});
