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
    </div>
  );
}
