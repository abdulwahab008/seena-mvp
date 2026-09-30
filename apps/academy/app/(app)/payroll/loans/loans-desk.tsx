'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  StaffLoanSummaryRow,
  createStaffLoan,
  recordLoanPayoff,
  ActionState,
} from '../actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Modal } from '@/components/ui/modal';
import {
  Plus,
  DollarSign,
  CheckCircle2,
  AlertCircle,
  CreditCard,
  Wallet,
  ArrowDownCircle,
} from 'lucide-react';

interface Props {
  initialLoans: StaffLoanSummaryRow[];
  staffList: Array<{ id: string; name: string; code: string }>;
}

export function LoansDesk({ initialLoans, staffList }: Props) {
  const router = useRouter();
  const [loans] = useState<StaffLoanSummaryRow[]>(initialLoans);
  const [createModalOpen, setCreateModalOpen] = useState(false);
  const [payoffModalOpen, setPayoffModalOpen] = useState(false);
  const [selectedLoan, setSelectedLoan] = useState<StaffLoanSummaryRow | null>(null);
  const [isPending, startTransition] = useTransition();

  const totalDisbursedPaisa = loans.reduce((acc, l) => acc + Number(l.principal_paisa || 0), 0);
  const totalRepaidPaisa = loans.reduce((acc, l) => acc + Number(l.total_repaid_paisa || 0), 0);
  const totalOutstandingPaisa = loans.reduce((acc, l) => acc + Number(l.outstanding_paisa || 0), 0);

  const formatPkr = (paisa: number) => {
    return new Intl.NumberFormat('en-PK', {
      style: 'currency',
      currency: 'PKR',
      maximumFractionDigits: 0,
    }).format(paisa / 100);
  };

  const handleCreateSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const formData = new FormData(e.currentTarget);

    startTransition(async () => {
      const res: ActionState = await createStaffLoan({ error: null }, formData);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Loan / Advance disbursed successfully.');
        setCreateModalOpen(false);
        router.refresh();
      }
    });
  };

  const handlePayoffSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (!selectedLoan) return;

    const formData = new FormData(e.currentTarget);
    formData.set('loan_id', selectedLoan.id);

    startTransition(async () => {
      const res: ActionState = await recordLoanPayoff({ error: null }, formData);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Lump sum payment recorded.');
        setPayoffModalOpen(false);
        setSelectedLoan(null);
        router.refresh();
      }
    });
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 pb-4 border-b border-slate-200 dark:border-slate-800">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Staff Loans & Salary Advances
          </h1>
          <p className="text-sm text-slate-500 dark:text-slate-400 mt-1">
            Manage principal disbursements, automated monthly payroll recovery installments, and payoffs.
          </p>
        </div>
        <Button onClick={() => setCreateModalOpen(true)} className="gap-2 shadow-sm">
          <Plus className="w-4 h-4" />
          Disburse New Loan / Advance
        </Button>
      </div>

      {/* KPI Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm flex items-center gap-4">
          <div className="w-12 h-12 rounded-lg bg-blue-50 dark:bg-blue-950/40 text-blue-600 dark:text-blue-400 flex items-center justify-center font-bold">
            <Wallet className="w-6 h-6" />
          </div>
          <div>
            <div className="text-sm text-slate-500 font-medium">Total Disbursed</div>
            <div className="text-2xl font-bold text-slate-900 dark:text-slate-100">
              {formatPkr(totalDisbursedPaisa)}
            </div>
          </div>
        </div>

        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm flex items-center gap-4">
          <div className="w-12 h-12 rounded-lg bg-emerald-50 dark:bg-emerald-950/40 text-emerald-600 dark:text-emerald-400 flex items-center justify-center font-bold">
            <ArrowDownCircle className="w-6 h-6" />
          </div>
          <div>
            <div className="text-sm text-slate-500 font-medium">Total Recovered</div>
            <div className="text-2xl font-bold text-slate-900 dark:text-slate-100">
              {formatPkr(totalRepaidPaisa)}
            </div>
          </div>
        </div>

        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm flex items-center gap-4">
          <div className="w-12 h-12 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-600 dark:text-amber-400 flex items-center justify-center font-bold">
            <AlertCircle className="w-6 h-6" />
          </div>
          <div>
            <div className="text-sm text-slate-500 font-medium">Outstanding Balance</div>
            <div className="text-2xl font-bold text-amber-600 dark:text-amber-400">
              {formatPkr(totalOutstandingPaisa)}
            </div>
          </div>
        </div>
      </div>

      {/* Loans Table */}
      <div className="rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 overflow-hidden shadow-sm">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 dark:border-slate-800 bg-slate-50/75 dark:bg-slate-800/50 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                <th className="py-3.5 px-4">Staff Member</th>
                <th className="py-3.5 px-4">Type</th>
                <th className="py-3.5 px-4">Principal Amount</th>
                <th className="py-3.5 px-4">Monthly Recovery</th>
                <th className="py-3.5 px-4">Repaid</th>
                <th className="py-3.5 px-4">Outstanding</th>
                <th className="py-3.5 px-4">Status</th>
                <th className="py-3.5 px-4 text-right">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200 dark:divide-slate-800 text-sm">
              {loans.length === 0 ? (
                <tr>
                  <td colSpan={8} className="py-8 text-center text-slate-500 dark:text-slate-400">
                    No staff loans or advances recorded.
                  </td>
                </tr>
              ) : (
                loans.map((l) => (
                  <tr key={l.id} className="hover:bg-slate-50/50 dark:hover:bg-slate-800/30 transition-colors">
                    <td className="py-3.5 px-4">
                      <div>
                        <div className="font-semibold text-slate-900 dark:text-slate-100">{l.staff_name}</div>
                        <div className="text-xs font-mono text-slate-400">{l.employee_code}</div>
                      </div>
                    </td>
                    <td className="py-3.5 px-4">
                      {l.loan_type === 'salary_advance' ? (
                        <Badge variant="default" className="bg-purple-100 dark:bg-purple-950 text-purple-700 dark:text-purple-300">
                          Advance
                        </Badge>
                      ) : (
                        <Badge variant="outline" className="border-blue-400 text-blue-600">
                          Term Loan
                        </Badge>
                      )}
                    </td>
                    <td className="py-3.5 px-4 font-medium text-slate-900 dark:text-slate-100">
                      {formatPkr(l.principal_paisa)}
                    </td>
                    <td className="py-3.5 px-4 text-slate-600 dark:text-slate-300">
                      {formatPkr(l.installment_paisa)}
                      <span className="text-xs text-slate-400">/mo</span>
                    </td>
                    <td className="py-3.5 px-4 text-emerald-600 dark:text-emerald-400 font-medium">
                      {formatPkr(l.total_repaid_paisa)}
                    </td>
                    <td className="py-3.5 px-4 font-bold text-slate-900 dark:text-slate-100">
                      {formatPkr(l.outstanding_paisa)}
                    </td>
                    <td className="py-3.5 px-4">
                      {l.status === 'closed' ? (
                        <Badge variant="outline" className="text-slate-400 border-slate-300">
                          Closed
                        </Badge>
                      ) : l.status === 'active' ? (
                        <Badge variant="default" className="bg-emerald-600">
                          Active
                        </Badge>
                      ) : (
                        <Badge variant="default">{l.status}</Badge>
                      )}
                    </td>
                    <td className="py-3.5 px-4 text-right">
                      {l.status === 'active' && l.outstanding_paisa > 0 && (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => {
                            setSelectedLoan(l);
                            setPayoffModalOpen(true);
                          }}
                          className="gap-1 text-xs h-8"
                        >
                          <CreditCard className="w-3.5 h-3.5" />
                          Payoff
                        </Button>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Create Modal */}
      <Modal
        open={createModalOpen}
        onClose={() => setCreateModalOpen(false)}
        title="Disburse Staff Loan or Salary Advance"
        description="Creates a recovery schedule that automatically deducts from monthly payroll generation."
      >
        <form onSubmit={handleCreateSubmit} className="space-y-4 pt-2">
          <div className="space-y-1.5">
            <Label htmlFor="staff_id">Staff Member *</Label>
            <select
              id="staff_id"
              name="staff_id"
              required
              className="w-full h-10 px-3 rounded-md border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 text-sm"
            >
              <option value="">-- Choose employee --</option>
              {staffList.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name} ({s.code})
                </option>
              ))}
            </select>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="loan_type">Facility Type</Label>
              <select
                id="loan_type"
                name="loan_type"
                className="w-full h-10 px-3 rounded-md border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 text-sm"
              >
                <option value="loan">Staff Loan (Multi-Month)</option>
                <option value="salary_advance">Emergency Advance</option>
              </select>
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="principal_pkr">Principal Amount (PKR) *</Label>
              <Input
                id="principal_pkr"
                name="principal_pkr"
                type="number"
                min="1"
                step="1"
                placeholder="e.g. 100000"
                required
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="installment_pkr">Monthly Installment (PKR) *</Label>
              <Input
                id="installment_pkr"
                name="installment_pkr"
                type="number"
                min="1"
                step="1"
                placeholder="e.g. 10000"
                required
              />
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="disbursed_at">Disbursement Date</Label>
              <Input
                id="disbursed_at"
                name="disbursed_at"
                type="date"
                defaultValue={new Date().toISOString().slice(0, 10)}
                required
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="repayment_start_month">Recovery Start Month</Label>
            <Input
              id="repayment_start_month"
              name="repayment_start_month"
              type="date"
              defaultValue={new Date().toISOString().slice(0, 7) + '-01'}
              required
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="notes">Notes / Purpose</Label>
            <Input
              id="notes"
              name="notes"
              placeholder="e.g. Medical emergency or home renovation advance"
            />
          </div>

          <div className="flex justify-end gap-2 pt-4 border-t border-slate-200 dark:border-slate-800">
            <Button
              type="button"
              variant="outline"
              onClick={() => setCreateModalOpen(false)}
              disabled={isPending}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={isPending}>
              {isPending ? 'Processing...' : 'Disburse Facility'}
            </Button>
          </div>
        </form>
      </Modal>

      {/* Lump-Sum Payoff Modal */}
      <Modal
        open={payoffModalOpen}
        onClose={() => setPayoffModalOpen(false)}
        title="Record Early Loan Payoff"
        description={`Record manual settlement for ${selectedLoan?.staff_name || 'employee'}.`}
      >
        <form onSubmit={handlePayoffSubmit} className="space-y-4 pt-2">
          {selectedLoan && (
            <div className="p-3 rounded-lg bg-slate-50 dark:bg-slate-800 text-sm space-y-1">
              <div className="flex justify-between">
                <span className="text-slate-500">Remaining Balance:</span>
                <span className="font-bold text-slate-900 dark:text-slate-100">
                  {formatPkr(selectedLoan.outstanding_paisa)}
                </span>
              </div>
            </div>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="amount_pkr">Payoff Amount (PKR) *</Label>
            <Input
              id="amount_pkr"
              name="amount_pkr"
              type="number"
              min="1"
              max={selectedLoan ? selectedLoan.outstanding_paisa / 100 : undefined}
              defaultValue={selectedLoan ? selectedLoan.outstanding_paisa / 100 : 0}
              required
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="notes">Reference / Notes</Label>
            <Input
              id="notes"
              name="notes"
              placeholder="e.g. Direct cash deposit or bank receipt #1234"
              defaultValue="Direct lump sum payment"
            />
          </div>

          <div className="flex justify-end gap-2 pt-4 border-t border-slate-200 dark:border-slate-800">
            <Button
              type="button"
              variant="outline"
              onClick={() => setPayoffModalOpen(false)}
              disabled={isPending}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={isPending}>
              {isPending ? 'Recording...' : 'Confirm Payment'}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
