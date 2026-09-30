'use client';

import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';

type ChallanLine = {
  id: string;
  headName: string;
  lineType: string;
  amountPaisa: number;
  concessionPaisa: number;
  netPaisa: number;
};

type ChallanModalProps = {
  challan: {
    id: string;
    challanNo: string;
    billingPeriod: string;
    issueDate: string;
    dueDate: string;
    netPaisa: number;
    grossPaisa: number;
    concessionPaisa: number;
    arrearsPaisa: number;
    status: string;
    lines: ChallanLine[];
    studentName: string;
    sectionLabel: string;
    grNumber?: string;
    bankName?: string;
    bankAccountTitle?: string;
    bankAccountNo?: string;
  };
};

export function ChallanActionsClient({ challan }: ChallanModalProps) {
  const [showSlip, setShowSlip] = useState(false);
  const [showPay, setShowPay] = useState(false);

  const formatPkr = (paisa: number) => {
    return `PKR ${(paisa / 100).toLocaleString('en-PK', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
  };

  const isOverdue =
    challan.status !== 'paid' &&
    new Date(`${challan.dueDate}T23:59:59`) < new Date();

  return (
    <div className="flex flex-wrap items-center gap-2">
      <Button
        variant="outline"
        size="sm"
        onClick={() => setShowSlip(true)}
        data-testid={`view-slip-${challan.challanNo}`}
      >
        View Challan Slip
      </Button>

      {challan.status !== 'paid' && (
        <Button
          size="sm"
          onClick={() => setShowPay(true)}
          data-testid={`pay-online-${challan.challanNo}`}
          className="bg-emerald-600 hover:bg-emerald-700 text-white"
        >
          Pay Online
        </Button>
      )}

      {/* Challan Slip Modal */}
      {showSlip && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm">
          <div className="relative max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-xl border bg-card p-6 shadow-2xl">
            <div className="flex items-center justify-between border-b pb-4">
              <div>
                <h3 className="text-lg font-bold">Fee Challan #{challan.challanNo}</h3>
                <p className="text-xs text-muted-foreground">Billing Period: {challan.billingPeriod}</p>
              </div>
              <Button variant="ghost" size="sm" onClick={() => setShowSlip(false)}>
                ✕
              </Button>
            </div>

            {/* School and Bank Details */}
            <div className="mt-4 grid grid-cols-2 gap-4 rounded-lg bg-muted/40 p-4 text-xs">
              <div>
                <span className="font-semibold text-muted-foreground">Student:</span> {challan.studentName}
                <br />
                <span className="font-semibold text-muted-foreground">Class & Section:</span> {challan.sectionLabel}
              </div>
              <div>
                <span className="font-semibold text-muted-foreground">Bank:</span> {challan.bankName || 'Askari Bank Ltd'}
                <br />
                <span className="font-semibold text-muted-foreground">Account Title:</span> {challan.bankAccountTitle || 'Seena Academy Collection'}
                <br />
                <span className="font-semibold text-muted-foreground">A/C No:</span>{' '}
                <span className="font-mono font-bold">{challan.bankAccountNo || '0123-4567890123'}</span>
              </div>
            </div>

            {/* Dates & Net Due */}
            <div className="mt-3 flex items-center justify-between rounded-lg border border-dashed p-3 text-xs">
              <div>
                <span className="text-muted-foreground">Issue Date:</span> {challan.issueDate}
              </div>
              <div>
                <span className="text-muted-foreground">Due Date:</span>{' '}
                <span className={isOverdue ? 'font-bold text-rose-600' : 'font-semibold'}>
                  {challan.dueDate} {isOverdue && '(Overdue)'}
                </span>
              </div>
              <div>
                <span className="text-muted-foreground">Total Payable:</span>{' '}
                <span className="text-sm font-bold text-emerald-600 dark:text-emerald-400">
                  {formatPkr(challan.netPaisa)}
                </span>
              </div>
            </div>

            {/* Line Items */}
            <div className="mt-4">
              <h4 className="text-xs font-semibold uppercase text-muted-foreground mb-2">Fee Head Breakdown</h4>
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="py-1.5">Description</th>
                    <th className="py-1.5 text-right">Amount</th>
                    <th className="py-1.5 text-right">Concession</th>
                    <th className="py-1.5 text-right">Net</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {challan.lines.map((l) => (
                    <tr key={l.id}>
                      <td className="py-1.5 font-medium">{l.headName}</td>
                      <td className="py-1.5 text-right font-mono">{formatPkr(l.amountPaisa)}</td>
                      <td className="py-1.5 text-right font-mono text-emerald-600">
                        {l.concessionPaisa > 0 ? `-${formatPkr(l.concessionPaisa)}` : '—'}
                      </td>
                      <td className="py-1.5 text-right font-mono font-semibold">{formatPkr(l.netPaisa)}</td>
                    </tr>
                  ))}
                  {challan.arrearsPaisa > 0 && (
                    <tr>
                      <td className="py-1.5 font-medium text-amber-600">Previous Arrears</td>
                      <td className="py-1.5 text-right font-mono">—</td>
                      <td className="py-1.5 text-right font-mono">—</td>
                      <td className="py-1.5 text-right font-mono font-semibold text-amber-600">
                        {formatPkr(challan.arrearsPaisa)}
                      </td>
                    </tr>
                  )}
                </tbody>
                <tfoot>
                  <tr className="border-t-2 font-bold text-sm">
                    <td className="py-2">Net Total Amount</td>
                    <td colSpan={3} className="py-2 text-right text-emerald-600">
                      {formatPkr(challan.netPaisa)}
                    </td>
                  </tr>
                </tfoot>
              </table>
            </div>

            {/* Three-part note */}
            <div className="mt-4 rounded border bg-muted/20 p-2.5 text-center text-[11px] text-muted-foreground">
              Note: Payable at any branch of the designated bank nationwide. Deposit via cash or 1Link 1Bill using Challan No as consumer number.
            </div>

            <div className="mt-6 flex justify-end gap-2">
              <Button variant="outline" size="sm" onClick={() => window.print()}>
                Print Slip
              </Button>
              <Button size="sm" onClick={() => setShowSlip(false)}>
                Close
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* Pay Online Modal */}
      {showPay && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm">
          <div className="relative max-h-[90vh] w-full max-w-md rounded-xl border bg-card p-6 shadow-2xl">
            <div className="flex items-center justify-between border-b pb-3">
              <h3 className="text-base font-bold">Pay Fee Online</h3>
              <Button variant="ghost" size="sm" onClick={() => setShowPay(false)}>
                ✕
              </Button>
            </div>

            <div className="mt-4 space-y-4 text-sm">
              <div className="rounded-lg bg-emerald-50 dark:bg-emerald-950/30 p-3 text-center border border-emerald-200 dark:border-emerald-900">
                <span className="text-xs text-muted-foreground">Amount to Pay</span>
                <div className="text-2xl font-bold text-emerald-600 dark:text-emerald-400">
                  {formatPkr(challan.netPaisa)}
                </div>
                <span className="text-xs font-medium">Challan No: {challan.challanNo}</span>
              </div>

              <div className="space-y-3">
                <div className="rounded-lg border p-3">
                  <div className="font-semibold text-xs text-primary mb-1">Option 1: 1Link 1Bill Invoice</div>
                  <p className="text-xs text-muted-foreground">
                    Pay through your mobile banking app (HBL, Meezan, Alfalah, etc.) using 1Bill Invoice / Voucher.
                  </p>
                  <div className="mt-2 flex items-center justify-between bg-muted p-2 rounded text-xs font-mono">
                    <span>Biller Code / ID:</span>
                    <span className="font-bold">{challan.challanNo.replace(/[^0-9]/g, '') || '1004829381'}</span>
                  </div>
                </div>

                <div className="rounded-lg border p-3">
                  <div className="font-semibold text-xs text-primary mb-1">Option 2: JazzCash &amp; EasyPaisa</div>
                  <p className="text-xs text-muted-foreground">
                    Go to Payments &rarr; School &amp; Education &rarr; Search &ldquo;Seena Academy&rdquo; &rarr; Enter Challan No.
                  </p>
                </div>

                <div className="rounded-lg border p-3">
                  <div className="font-semibold text-xs text-primary mb-1">Option 3: Bank Counter Deposit</div>
                  <p className="text-xs text-muted-foreground">
                    Visit any branch of {challan.bankName || 'Askari Bank'} with your printed challan slip and deposit cash directly.
                  </p>
                </div>
              </div>
            </div>

            <div className="mt-6 flex justify-end">
              <Button size="sm" onClick={() => setShowPay(false)}>
                Understood
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
