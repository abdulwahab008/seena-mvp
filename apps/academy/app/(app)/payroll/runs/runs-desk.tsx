'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { toast } from 'sonner';
import {
  PayrollRunRow,
  generatePayrollRunAction,
  submitPayrollRunForApproval,
  approvePayrollRun,
  lockPayrollRun,
} from '../actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Modal } from '@/components/ui/modal';
import {
  Play,
  CheckCircle2,
  Lock,
  Send,
  Calendar,
  DollarSign,
  Users,
  ChevronRight,
  ShieldAlert,
} from 'lucide-react';

interface Props {
  initialRuns: PayrollRunRow[];
  campuses: Array<{ id: string; code: string; name: string }>;
  selectedCampusId: string | null;
}

export function RunsDesk({ initialRuns, campuses, selectedCampusId }: Props) {
  const router = useRouter();
  const [runs] = useState<PayrollRunRow[]>(initialRuns);
  const [generateModalOpen, setGenerateModalOpen] = useState(false);
  const [isPending, startTransition] = useTransition();

  const handleGenerate = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const formData = new FormData(e.currentTarget);
    const campusId = formData.get('campus_id')?.toString() || '';
    const period = formData.get('period_month')?.toString() || '';

    if (!campusId || !period) {
      toast.error('Campus and Month are required.');
      return;
    }

    startTransition(async () => {
      const res = await generatePayrollRunAction(campusId, period + '-01');
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Payroll run generated successfully.');
        setGenerateModalOpen(false);
        if (res.runId) {
          router.push(`/payroll/runs/${res.runId}`);
        } else {
          router.refresh();
        }
      }
    });
  };

  const handleSubmitApproval = (runId: string) => {
    startTransition(async () => {
      const res = await submitPayrollRunForApproval(runId);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Payroll submitted for approval.');
        router.refresh();
      }
    });
  };

  const handleApprove = (runId: string) => {
    startTransition(async () => {
      const res = await approvePayrollRun(runId);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Payroll run approved.');
        router.refresh();
      }
    });
  };

  const handleLock = (runId: string) => {
    if (!confirm('Locking a payroll run permanently freezes all line items, tax withholdings, and loan recoveries. Proceed?')) {
      return;
    }

    startTransition(async () => {
      const res = await lockPayrollRun(runId);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Payroll run locked and made immutable.');
        router.refresh();
      }
    });
  };

  const formatPkr = (paisa: number) => {
    return new Intl.NumberFormat('en-PK', {
      style: 'currency',
      currency: 'PKR',
      maximumFractionDigits: 0,
    }).format(paisa / 100);
  };

  const getStatusBadge = (status: string) => {
    switch (status) {
      case 'draft':
        return <Badge variant="default" className="bg-slate-100 dark:bg-slate-800 text-slate-700 dark:text-slate-300">Draft</Badge>;
      case 'pending_approval':
        return <Badge variant="outline" className="border-amber-400 text-amber-600 bg-amber-50/50">Pending Approval</Badge>;
      case 'locked':
        return (
          <Badge variant="default" className="bg-slate-900 dark:bg-slate-100 text-white dark:text-slate-900 flex items-center gap-1">
            <Lock className="w-3 h-3" />
            Locked
          </Badge>
        );
      case 'paid':
        return <Badge variant="default" className="bg-emerald-600">Disbursed / Paid</Badge>;
      default:
        return <Badge variant="default">{status}</Badge>;
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 pb-4 border-b border-slate-200 dark:border-slate-800">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Monthly Payroll Runs & Approvals
          </h1>
          <p className="text-sm text-slate-500 dark:text-slate-400 mt-1">
            Generate monthly payrolls, audit component breakdowns, enforce approval policies, and lock payslips.
          </p>
        </div>
        <Button onClick={() => setGenerateModalOpen(true)} className="gap-2 shadow-sm bg-blue-600 hover:bg-blue-700 text-white">
          <Play className="w-4 h-4" />
          Generate Payroll Run
        </Button>
      </div>

      {/* Runs Table */}
      <div className="rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 overflow-hidden shadow-sm">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 dark:border-slate-800 bg-slate-50/75 dark:bg-slate-800/50 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                <th className="py-3.5 px-4">Period Month</th>
                <th className="py-3.5 px-4">Campus</th>
                <th className="py-3.5 px-4">Staff Count</th>
                <th className="py-3.5 px-4">Total Gross</th>
                <th className="py-3.5 px-4">Deductions</th>
                <th className="py-3.5 px-4">Net Disbursable</th>
                <th className="py-3.5 px-4">Status</th>
                <th className="py-3.5 px-4 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200 dark:divide-slate-800 text-sm">
              {runs.length === 0 ? (
                <tr>
                  <td colSpan={8} className="py-8 text-center text-slate-500 dark:text-slate-400">
                    No payroll runs generated yet. Click &quot;Generate Payroll Run&quot; to compute this month&apos;s salaries.
                  </td>
                </tr>
              ) : (
                runs.map((r) => (
                  <tr key={r.id} className="hover:bg-slate-50/50 dark:hover:bg-slate-800/30 transition-colors">
                    <td className="py-3.5 px-4 font-semibold text-slate-900 dark:text-slate-100">
                      <div className="flex items-center gap-1.5 font-mono">
                        <Calendar className="w-4 h-4 text-blue-500" />
                        {new Date(r.period_month).toLocaleDateString('en-PK', {
                          month: 'long',
                          year: 'numeric',
                        })}
                      </div>
                    </td>
                    <td className="py-3.5 px-4 text-slate-600 dark:text-slate-300">
                      {r.campus_name}
                    </td>
                    <td className="py-3.5 px-4">
                      <div className="flex items-center gap-1 text-slate-700 dark:text-slate-300 font-medium">
                        <Users className="w-3.5 h-3.5 text-slate-400" />
                        {r.employee_count}
                      </div>
                    </td>
                    <td className="py-3.5 px-4 font-medium text-slate-900 dark:text-slate-100">
                      {formatPkr(r.total_gross_paisa)}
                    </td>
                    <td className="py-3.5 px-4 text-rose-600 dark:text-rose-400">
                      {formatPkr(r.total_deductions_paisa)}
                    </td>
                    <td className="py-3.5 px-4 font-bold text-emerald-600 dark:text-emerald-400">
                      {formatPkr(r.total_net_paisa)}
                    </td>
                    <td className="py-3.5 px-4">
                      {getStatusBadge(r.status)}
                    </td>
                    <td className="py-3.5 px-4 text-right">
                      <div className="flex items-center justify-end gap-1.5">
                        {r.status === 'draft' && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => handleSubmitApproval(r.id)}
                            disabled={isPending}
                            className="text-xs h-8 gap-1"
                          >
                            <Send className="w-3 h-3 text-amber-500" />
                            Submit
                          </Button>
                        )}

                        {r.status === 'pending_approval' && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => handleApprove(r.id)}
                            disabled={isPending}
                            className="text-xs h-8 gap-1 text-emerald-600 border-emerald-300"
                          >
                            <CheckCircle2 className="w-3 h-3" />
                            Approve
                          </Button>
                        )}

                        {r.status !== 'locked' && r.status !== 'paid' && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => handleLock(r.id)}
                            disabled={isPending}
                            className="text-xs h-8 gap-1 text-slate-700 dark:text-slate-300"
                          >
                            <Lock className="w-3 h-3" />
                            Lock
                          </Button>
                        )}

                        <Link href={`/payroll/runs/${r.id}`}>
                          <Button variant="ghost" size="sm" className="h-8 gap-1 text-xs">
                            <span>Details</span>
                            <ChevronRight className="w-3.5 h-3.5 text-slate-400" />
                          </Button>
                        </Link>
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Generate Run Modal */}
      <Modal
        open={generateModalOpen}
        onClose={() => setGenerateModalOpen(false)}
        title="Generate Monthly Payroll"
        description="Executes salary evaluation, absence proration deductions, income tax withholdings, and loan recoveries for all active employees."
      >
        <form onSubmit={handleGenerate} className="space-y-4 pt-2">
          <div className="space-y-1.5">
            <Label htmlFor="campus_id">Campus *</Label>
            <select
              id="campus_id"
              name="campus_id"
              required
              defaultValue={selectedCampusId || (campuses[0]?.id || '')}
              className="w-full h-10 px-3 rounded-md border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 text-sm"
            >
              {campuses.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name} ({c.code})
                </option>
              ))}
            </select>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="period_month">Payroll Month *</Label>
            <Input
              id="period_month"
              name="period_month"
              type="month"
              defaultValue={new Date().toISOString().slice(0, 7)}
              required
            />
          </div>

          <div className="p-3 rounded-lg bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800/40 text-xs text-amber-800 dark:text-amber-300 flex items-start gap-2">
            <ShieldAlert className="w-4 h-4 shrink-0 mt-0.5" />
            <span>
              If a draft run already exists for this campus and month, regenerating will recalculate and update all draft employee lines. Locked runs cannot be overwritten.
            </span>
          </div>

          <div className="flex justify-end gap-2 pt-4 border-t border-slate-200 dark:border-slate-800">
            <Button
              type="button"
              variant="outline"
              onClick={() => setGenerateModalOpen(false)}
              disabled={isPending}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={isPending} className="bg-blue-600 hover:bg-blue-700 text-white">
              {isPending ? 'Calculating...' : 'Run Payroll Engine'}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
