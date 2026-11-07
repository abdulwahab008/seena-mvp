export type ReportSale = {
  doc_type: 'sale' | 'credit_note';
  settlement: 'cash' | 'fee_ledger';
  total: number;
  lines: { item: string; qty: number; amount: number }[];
};

export type SalesSummary = {
  receipts: number;
  creditNotes: number;
  net: number;
  cash: number;
  feeLedger: number;
  items: { item: string; qty: number; amount: number }[];
};

// A credit note reverses part of a sale, so it counts against the totals.
export function summarizeSales(sales: ReportSale[]): SalesSummary {
  const items = new Map<string, { item: string; qty: number; amount: number }>();
  const s: SalesSummary = { receipts: 0, creditNotes: 0, net: 0, cash: 0, feeLedger: 0, items: [] };
  for (const sale of sales) {
    const sign = sale.doc_type === 'credit_note' ? -1 : 1;
    if (sign > 0) s.receipts++;
    else s.creditNotes++;
    s.net += sign * sale.total;
    if (sale.settlement === 'cash') s.cash += sign * sale.total;
    else s.feeLedger += sign * sale.total;
    for (const l of sale.lines) {
      const row = items.get(l.item) ?? { item: l.item, qty: 0, amount: 0 };
      row.qty += sign * l.qty;
      row.amount += sign * l.amount;
      items.set(l.item, row);
    }
  }
  s.items = [...items.values()].sort((a, b) => b.amount - a.amount || a.item.localeCompare(b.item));
  return s;
}
