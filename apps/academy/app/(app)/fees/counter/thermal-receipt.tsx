'use client';

import { formatPkr } from '@/lib/challan/html';
import { formatDateTimePk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import type { PrintResult } from './actions';

// An 80 mm receipt-printer slip. While printing, only the slip is visible and
// the page is sized to the roll, so the counter's normal printer driver is enough.
const PRINT_CSS = `@media print {
  @page { size: 80mm auto; margin: 3mm; }
  body * { visibility: hidden !important; }
  .thermal-receipt, .thermal-receipt * { visibility: visible !important; }
  .thermal-receipt { position: absolute; left: 0; top: 0; width: 74mm; }
}`;

export function ThermalReceipt({ receipt }: { receipt: PrintResult }) {
  return (
    <>
      <style>{PRINT_CSS}</style>
      <Button type="button" variant="outline" onClick={() => window.print()} data-testid="thermal-print-button">
        Print slip (80 mm)
      </Button>
      <div className="thermal-receipt hidden font-mono text-[11px] leading-tight text-black print:block" data-testid="thermal-receipt">
        {receipt.isDuplicate && <p className="text-center font-bold">*** DUPLICATE ***</p>}
        <p className="text-center font-bold">FEE RECEIPT</p>
        <p className="text-center">{receipt.receiptNo}</p>
        <p className="text-center">{formatDateTimePk(new Date().toISOString())}</p>
        <hr className="my-1 border-dashed border-black" />
        <p>{receipt.studentName}</p>
        <p>GR {receipt.grNumber}</p>
        <hr className="my-1 border-dashed border-black" />
        <p className="flex justify-between font-bold">
          <span>Paid</span>
          <span>{formatPkr(receipt.amountPaisa ?? 0)}</span>
        </p>
        <p>{receipt.amountWords}</p>
        <p className="flex justify-between">
          <span>Still due</span>
          <span>{formatPkr(receipt.postPaymentOutstandingPaisa ?? 0)}</span>
        </p>
        <hr className="my-1 border-dashed border-black" />
        <p className="text-center">Thank you</p>
      </div>
    </>
  );
}
