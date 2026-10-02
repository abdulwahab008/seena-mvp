'use client';

import * as React from 'react';
import { Printer, CheckCircle2, Building2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Modal } from '@/components/ui/modal';
import { Badge } from '@/components/ui/badge';

export interface PrintableReceiptModalProps {
  open: boolean;
  onClose: () => void;
  receiptData: {
    receiptNo: string;
    studentName: string;
    grNumber: string;
    applicationNo: string;
    className: string;
    sectionName: string;
    campusName: string;
    sessionName: string;
    parentName: string;
    feeAmount: number;
    paymentMode: string;
    date: string;
  } | null;
}

export function PrintableReceiptModal({ open, onClose, receiptData }: PrintableReceiptModalProps) {
  if (!receiptData) return null;

  const handlePrint = () => {
    window.print();
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Official Admission Receipt"
      description="Computer-generated payment slip for the student's records."
      size="md"
    >
      <div className="space-y-4 pt-1">
        {/* Printable Area */}
        <div id="admission-receipt-print-area" className="p-5 rounded-lg border bg-white dark:bg-zinc-900 shadow-sm space-y-4 text-zinc-900 dark:text-zinc-100 font-sans">
          {/* Header */}
          <div className="text-center border-b pb-3 space-y-1">
            <div className="flex items-center justify-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-indigo-700 dark:text-indigo-400">
              <Building2 className="h-3.5 w-3.5" />
              {receiptData.campusName}
            </div>
            <h2 className="text-lg font-bold tracking-tight">ADMISSION FEE RECEIPT</h2>
            <div className="flex items-center justify-center gap-2 text-xs text-muted-foreground font-mono">
              <span>Receipt: <strong className="text-foreground">{receiptData.receiptNo}</strong></span>
              <span>•</span>
              <span>Date: {receiptData.date}</span>
            </div>
          </div>

          {/* Student Particulars Table */}
          <div className="grid grid-cols-2 gap-2 text-xs py-1">
            <div>
              <span className="text-muted-foreground block">Student Name:</span>
              <span className="font-semibold text-sm">{receiptData.studentName}</span>
            </div>
            <div className="text-right">
              <span className="text-muted-foreground block">GR Number:</span>
              <span className="font-mono font-bold text-sm text-indigo-700 dark:text-indigo-400">
                {receiptData.grNumber}
              </span>
            </div>
            <div>
              <span className="text-muted-foreground block">Guardian:</span>
              <span className="font-medium">{receiptData.parentName}</span>
            </div>
            <div className="text-right">
              <span className="text-muted-foreground block">Class & Section:</span>
              <span className="font-medium">{receiptData.className} · Sec {receiptData.sectionName}</span>
            </div>
            <div>
              <span className="text-muted-foreground block">Academic Session:</span>
              <span className="font-medium">{receiptData.sessionName}</span>
            </div>
            <div className="text-right">
              <span className="text-muted-foreground block">Application Ref:</span>
              <span className="font-mono text-xs">{receiptData.applicationNo}</span>
            </div>
          </div>

          {/* Payment Line Items */}
          <div className="border-t border-b py-2 text-xs space-y-1">
            <div className="flex justify-between font-medium">
              <span>Admission & Enrolment Charges</span>
              <span>PKR {receiptData.feeAmount.toLocaleString()}</span>
            </div>
            <div className="flex justify-between text-muted-foreground">
              <span>Payment Mode:</span>
              <span className="capitalize">{receiptData.paymentMode}</span>
            </div>
            <div className="flex justify-between items-center pt-2 border-t font-bold text-sm">
              <span>Total Received:</span>
              <span className="text-green-700 dark:text-green-400">
                PKR {receiptData.feeAmount.toLocaleString()}
              </span>
            </div>
          </div>

          {/* Status & Stamp Footer */}
          <div className="flex items-center justify-between pt-2 text-[11px]">
            <div className="flex items-center gap-1 text-green-700 dark:text-green-400 font-semibold">
              <CheckCircle2 className="h-4 w-4" />
              <span>PAID & RECONCILED</span>
            </div>
            <div className="text-right text-muted-foreground">
              <div className="h-8 border-b border-dashed border-zinc-400 w-28 ml-auto" />
              <span className="text-[10px]">Cashier Stamp / Signature</span>
            </div>
          </div>
        </div>

        {/* Modal Footer Controls */}
        <div className="flex items-center justify-end gap-2 border-t pt-3">
          <Button variant="outline" size="sm" onClick={onClose}>
            Close
          </Button>
          <Button size="sm" onClick={handlePrint} className="gap-1.5 bg-indigo-600 hover:bg-indigo-700 text-white">
            <Printer className="h-4 w-4" />
            Print Receipt
          </Button>
        </div>
      </div>
    </Modal>
  );
}
