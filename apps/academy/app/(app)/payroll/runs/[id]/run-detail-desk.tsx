'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { toast } from 'sonner';
import {
  PayrollRunRow,
  PayrollRunLineRow,
  submitPayrollRunForApproval,
  approvePayrollRun,
  lockPayrollRun,
} from '../../actions';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Modal } from '@/components/ui/modal';
import {
  ArrowLeft,
  Calendar,
  Lock,
  CheckCircle2,
  Send,
  Download,
  FileText,
  UserCheck,
  TrendingDown,
  Building2,
  DollarSign,
} from 'lucide-react';

interface Props {
  run: PayrollRunRow;
  lines: PayrollRunLineRow[];
}

export function RunDetailDesk({ run, lines }: Props) {
  const router = useRouter();
  const [selectedLine, setSelectedLine] = useState<PayrollRunLineRow | null>(null);
  const [payslipModalOpen, setPayslipModalOpen] = useState(false);
  const [isPending, startTransition] = useTransition();

  const formatPkr = (paisa: number) => {
    return new Intl.NumberFormat('en-PK', {
      style: 'currency',
      currency: 'PKR',
      maximumFractionDigits: 0,
    }).format(paisa / 100);
  };

  const handleLock = () => {
    if (!confirm('Locking this payroll run will permanently seal all lines and components. This cannot be undone. Proceed?')) {
      return;
    }

    startTransition(async () => {
      const res = await lockPayrollRun(run.id);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Payroll run locked successfully.');
        router.refresh();
      }
    });
  };

  const handleApprove = () => {
    startTransition(async () => {
      const res = await approvePayrollRun(run.id);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Payroll run approved.');
        router.refresh();
      }
    });
  };

  const handleSubmit = () => {
    startTransition(async () => {
      const res = await submitPayrollRunForApproval(run.id);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Payroll submitted for approval.');
        router.refresh();
      }
    });
  };

  const exportBankDisbursementCsv = () => {
    const headers = ['Employee Code', 'Full Name', 'Gross (PKR)', 'Deductions (PKR)', 'Net Disbursable (PKR)', 'Status'];
    const rows = lines.map((l) => [
      `"${l.employee_code}"`,
      `"${l.staff_name}"`,
      (l.gross_paisa / 100).toFixed(2),
      ((l.attendance_deduction_paisa + l.tax_withholding_paisa + l.loan_recovery_paisa + l.other_deductions_paisa) / 100).toFixed(2),
      (l.net_paisa / 100).toFixed(2),
      `"${run.status}"`,
    ]);

    const csvContent = 'data:text/csv;charset=utf-8,' + [headers.join(','), ...rows.map((e) => e.join(','))].join('\n');
    const encodedUri = encodeURI(csvContent);
    const link = document.createElement('a');
    link.setAttribute('href', encodedUri);
    link.setAttribute('download', `payroll_${run.campus_name || 'campus'}_${run.period_month}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    toast.success('Salary disbursement file exported.');
  };

  return (
    <div className="space-y-6">
      {/* Top Bar Navigation & Actions */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 pb-4 border-b border-slate-200 dark:border-slate-800">
        <div className="flex items-center gap-3">
          <Link href="/payroll/runs">
            <Button variant="ghost" size="sm" className="h-9 w-9 p-0">
              <ArrowLeft className="w-5 h-5" />
            </Button>
          </Link>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
                {new Date(run.period_month).toLocaleDateString('en-PK', {
                  month: 'long',
                  year: 'numeric',
                })}{' '}
                Payroll Run
              </h1>
              {run.status === 'locked' ? (
                <Badge variant="default" className="bg-slate-900 text-white flex items-center gap-1">
                  <Lock className="w-3 h-3" /> Locked
                </Badge>
              ) : run.status === 'pending_approval' ? (
                <Badge variant="outline" className="border-amber-400 text-amber-600 bg-amber-50/50">
                  Pending Approval
                </Badge>
              ) : (
                <Badge variant="default">Draft</Badge>
              )}
            </div>
            <p className="text-xs text-slate-500 font-mono mt-0.5">
              Campus: {run.campus_name} &bull; Generated: {new Date(run.generated_at).toLocaleString('en-PK')}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={exportBankDisbursementCsv}
            className="gap-1.5 text-xs h-9"
          >
            <Download className="w-3.5 h-3.5" />
            Export Bank File (CSV)
          </Button>

          {run.status === 'draft' && (
            <Button
              size="sm"
              onClick={handleSubmit}
              disabled={isPending}
              className="gap-1.5 text-xs h-9 bg-amber-600 hover:bg-amber-700 text-white"
            >
              <Send className="w-3.5 h-3.5" />
              Submit for Approval
            </Button>
          )}

          {run.status === 'pending_approval' && (
            <Button
              size="sm"
              onClick={handleApprove}
              disabled={isPending}
              className="gap-1.5 text-xs h-9 bg-emerald-600 hover:bg-emerald-700 text-white"
            >
              <CheckCircle2 className="w-3.5 h-3.5" />
              Approve Payroll
            </Button>
          )}

          {run.status !== 'locked' && run.status !== 'paid' && (
            <Button
              size="sm"
              variant="outline"
              onClick={handleLock}
              disabled={isPending}
              className="gap-1.5 text-xs h-9 text-slate-800 dark:text-slate-200 border-slate-400"
            >
              <Lock className="w-3.5 h-3.5" />
              Lock Run
            </Button>
          )}
        </div>
      </div>

      {/* Summary KPI Cards */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm">
          <div className="text-xs text-slate-500 font-medium">Total Gross Earnings</div>
          <div className="text-xl font-bold text-slate-900 dark:text-slate-100 mt-1">
            {formatPkr(run.total_gross_paisa)}
          </div>
        </div>

        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm">
          <div className="text-xs text-rose-500 font-medium">Total Deductions</div>
          <div className="text-xl font-bold text-rose-600 dark:text-rose-400 mt-1">
            {formatPkr(run.total_deductions_paisa)}
          </div>
        </div>

        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm">
          <div className="text-xs text-emerald-600 font-medium">Net Disbursable</div>
          <div className="text-xl font-bold text-emerald-600 dark:text-emerald-400 mt-1">
            {formatPkr(run.total_net_paisa)}
          </div>
        </div>

        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm">
          <div className="text-xs text-slate-500 font-medium">Employees Processed</div>
          <div className="text-xl font-bold text-slate-900 dark:text-slate-100 mt-1">
            {run.employee_count}
          </div>
        </div>
      </div>

      {/* Employee Lines Table */}
      <div className="rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 overflow-hidden shadow-sm">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 dark:border-slate-800 bg-slate-50/75 dark:bg-slate-800/50 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                <th className="py-3.5 px-4">Staff Member</th>
                <th className="py-3.5 px-4">Basic</th>
                <th className="py-3.5 px-4">Unpaid Days</th>
                <th className="py-3.5 px-4">Gross Pay</th>
                <th className="py-3.5 px-4">Attendance Ded.</th>
                <th className="py-3.5 px-4">Tax Withheld</th>
                <th className="py-3.5 px-4">Loan Recovery</th>
                <th className="py-3.5 px-4">Net Salary</th>
                <th className="py-3.5 px-4 text-right">Payslip</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200 dark:divide-slate-800 text-sm">
              {lines.map((l) => (
                <tr key={l.id} className="hover:bg-slate-50/50 dark:hover:bg-slate-800/30 transition-colors">
                  <td className="py-3.5 px-4">
                    <div>
                      <div className="font-semibold text-slate-900 dark:text-slate-100">{l.staff_name}</div>
                      <div className="text-xs font-mono text-slate-400">{l.employee_code}</div>
                    </div>
                  </td>
                  <td className="py-3.5 px-4 text-slate-600 dark:text-slate-300">
                    {formatPkr(l.basic_paisa)}
                  </td>
                  <td className="py-3.5 px-4">
                    {l.unpaid_days > 0 ? (
                      <Badge variant="destructive" className="font-mono text-xs">
                        {l.unpaid_days} d
                      </Badge>
                    ) : (
                      <span className="text-xs text-slate-400 font-mono">0</span>
                    )}
                  </td>
                  <td className="py-3.5 px-4 font-medium text-slate-900 dark:text-slate-100">
                    {formatPkr(l.gross_paisa)}
                  </td>
                  <td className="py-3.5 px-4 text-rose-600 dark:text-rose-400">
                    {l.attendance_deduction_paisa > 0 ? formatPkr(l.attendance_deduction_paisa) : '-'}
                  </td>
                  <td className="py-3.5 px-4 text-rose-600 dark:text-rose-400">
                    {l.tax_withholding_paisa > 0 ? formatPkr(l.tax_withholding_paisa) : '-'}
                  </td>
                  <td className="py-3.5 px-4 text-rose-600 dark:text-rose-400">
                    {l.loan_recovery_paisa > 0 ? formatPkr(l.loan_recovery_paisa) : '-'}
                  </td>
                  <td className="py-3.5 px-4 font-bold text-emerald-600 dark:text-emerald-400">
                    {formatPkr(l.net_paisa)}
                  </td>
                  <td className="py-3.5 px-4 text-right">
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => {
                        setSelectedLine(l);
                        setPayslipModalOpen(true);
                      }}
                      className="h-8 gap-1 text-xs text-blue-600 hover:text-blue-700"
                    >
                      <FileText className="w-3.5 h-3.5" />
                      Breakdown
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Payslip & Breakdown Modal */}
      <Modal
        open={payslipModalOpen}
        onClose={() => setPayslipModalOpen(false)}
        title={`Payslip Breakdown: ${selectedLine?.staff_name || ''}`}
        description={`Period: ${new Date(run.period_month).toLocaleDateString('en-PK', { month: 'long', year: 'numeric' })} &bull; Code: ${selectedLine?.employee_code || ''}`}
      >
        {selectedLine && (
          <div className="space-y-4 pt-2 text-sm">
            {/* Attendance & Basis */}
            <div className="grid grid-cols-2 gap-2 p-3 rounded-lg bg-slate-50 dark:bg-slate-800 text-xs">
              <div>
                <span className="text-slate-500">Payable Days Basis:</span>{' '}
                <strong className="font-mono">{selectedLine.payable_days} days</strong>
              </div>
              <div>
                <span className="text-slate-500">Unpaid Absences:</span>{' '}
                <strong className="font-mono text-rose-600">{selectedLine.unpaid_days} days</strong>
              </div>
            </div>

            {/* Earnings breakdown */}
            <div className="space-y-2">
              <h3 className="font-semibold text-xs uppercase tracking-wider text-slate-500">Earnings Components</h3>
              <div className="rounded-lg border border-slate-200 dark:border-slate-800 divide-y divide-slate-100 dark:divide-slate-800">
                {(selectedLine.components || [])
                  .filter((c) => c.component_type === 'earning')
                  .map((c) => (
                    <div key={c.id} className="p-2.5 flex items-center justify-between">
                      <div className="flex items-center gap-1.5">
                        <span className="font-mono text-xs text-slate-400">{c.code}</span>
                        <span>{c.name_en}</span>
                        {c.is_taxable && <span className="text-[10px] text-amber-600 bg-amber-50 px-1 rounded">Taxable</span>}
                      </div>
                      <span className="font-medium text-slate-900 dark:text-slate-100">{formatPkr(c.amount_paisa)}</span>
                    </div>
                  ))}
                <div className="p-2.5 flex items-center justify-between bg-slate-50/50 dark:bg-slate-800/30 font-bold">
                  <span>Gross Earnings</span>
                  <span className="text-slate-900 dark:text-slate-100">{formatPkr(selectedLine.gross_paisa)}</span>
                </div>
              </div>
            </div>

            {/* Deductions breakdown */}
            <div className="space-y-2">
              <h3 className="font-semibold text-xs uppercase tracking-wider text-slate-500">Deductions</h3>
              <div className="rounded-lg border border-slate-200 dark:border-slate-800 divide-y divide-slate-100 dark:divide-slate-800">
                {selectedLine.attendance_deduction_paisa > 0 && (
                  <div className="p-2.5 flex items-center justify-between text-rose-600 dark:text-rose-400">
                    <span>Attendance Deduction ({selectedLine.unpaid_days} days)</span>
                    <span>-{formatPkr(selectedLine.attendance_deduction_paisa)}</span>
                  </div>
                )}
                {selectedLine.tax_withholding_paisa > 0 && (
                  <div className="p-2.5 flex items-center justify-between text-rose-600 dark:text-rose-400">
                    <span>Income Tax Withholding</span>
                    <span>-{formatPkr(selectedLine.tax_withholding_paisa)}</span>
                  </div>
                )}
                {selectedLine.loan_recovery_paisa > 0 && (
                  <div className="p-2.5 flex items-center justify-between text-rose-600 dark:text-rose-400">
                    <span>Loan / Advance Recovery</span>
                    <span>-{formatPkr(selectedLine.loan_recovery_paisa)}</span>
                  </div>
                )}
                {(selectedLine.components || [])
                  .filter((c) => c.component_type === 'deduction')
                  .map((c) => (
                    <div key={c.id} className="p-2.5 flex items-center justify-between text-rose-600 dark:text-rose-400">
                      <span>{c.name_en}</span>
                      <span>-{formatPkr(c.amount_paisa)}</span>
                    </div>
                  ))}
              </div>
            </div>

            {/* Net Salary highlight */}
            <div className="p-4 rounded-xl bg-emerald-50 dark:bg-emerald-950/40 border border-emerald-200 dark:border-emerald-800 flex items-center justify-between">
              <div>
                <div className="text-xs text-emerald-700 dark:text-emerald-300 font-medium">Net Disbursable Salary</div>
                <div className="text-xs text-emerald-600 dark:text-emerald-400">Transferred to verified employee bank account</div>
              </div>
              <div className="text-2xl font-bold text-emerald-700 dark:text-emerald-300">
                {formatPkr(selectedLine.net_paisa)}
              </div>
            </div>

            <div className="flex justify-end pt-2">
              <Button variant="outline" onClick={() => setPayslipModalOpen(false)}>
                Close
              </Button>
            </div>
          </div>
        )}
      </Modal>
    </div>
  );
}
