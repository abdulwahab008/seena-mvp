'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  SalaryComponentRow,
  saveSalaryComponent,
  ActionState,
} from '../actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Modal } from '@/components/ui/modal';
import {
  Plus,
  Edit2,
  DollarSign,
  TrendingDown,
  Building2,
  CheckCircle,
  XCircle,
  Percent,
} from 'lucide-react';

interface Props {
  initialComponents: SalaryComponentRow[];
}

export function ComponentsDesk({ initialComponents }: Props) {
  const router = useRouter();
  const [components] = useState<SalaryComponentRow[]>(initialComponents);
  const [modalOpen, setModalOpen] = useState(false);
  const [selectedComp, setSelectedComp] = useState<SalaryComponentRow | null>(null);
  const [isPending, startTransition] = useTransition();

  // Form states
  const [componentType, setComponentType] = useState<'earning' | 'deduction' | 'employer_contribution'>('earning');
  const [calcMethod, setCalcMethod] = useState<'fixed_paisa' | 'pct_of_basic' | 'pct_of_gross'>('fixed_paisa');
  const [isTaxable, setIsTaxable] = useState(true);
  const [prorates, setProrates] = useState(true);

  const openCreateModal = () => {
    setSelectedComp(null);
    setComponentType('earning');
    setCalcMethod('fixed_paisa');
    setIsTaxable(true);
    setProrates(true);
    setModalOpen(true);
  };

  const openEditModal = (c: SalaryComponentRow) => {
    setSelectedComp(c);
    setComponentType(c.component_type);
    setCalcMethod(c.calc_method);
    setIsTaxable(c.is_taxable);
    setProrates(c.prorates_on_absence);
    setModalOpen(true);
  };

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const formData = new FormData(e.currentTarget);
    formData.set('component_type', componentType);
    formData.set('calc_method', calcMethod);
    formData.set('is_taxable', isTaxable ? 'true' : 'false');
    formData.set('prorates_on_absence', prorates ? 'true' : 'false');
    if (selectedComp) {
      formData.set('id', selectedComp.id);
    }

    startTransition(async () => {
      const res: ActionState = await saveSalaryComponent({ error: null }, formData);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(selectedComp ? 'Component updated' : 'Component created');
        setModalOpen(false);
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

  const getTypeBadge = (type: string) => {
    switch (type) {
      case 'earning':
        return <Badge variant="default" className="bg-emerald-600 hover:bg-emerald-700">Earning</Badge>;
      case 'deduction':
        return <Badge variant="destructive">Deduction</Badge>;
      case 'employer_contribution':
        return <Badge variant="outline" className="border-indigo-500 text-indigo-700">Employer</Badge>;
      default:
        return <Badge variant="default">{type}</Badge>;
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 pb-4 border-b border-slate-200 dark:border-slate-800">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Salary Component Catalogue
          </h1>
          <p className="text-sm text-slate-500 dark:text-slate-400 mt-1">
            Configure standardized earnings, deductions, calculation rules, and absence proration for payroll.
          </p>
        </div>
        <Button onClick={openCreateModal} className="gap-2 shadow-sm">
          <Plus className="w-4 h-4" />
          Add Salary Component
        </Button>
      </div>

      {/* Stats row */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm flex items-center gap-4">
          <div className="w-12 h-12 rounded-lg bg-emerald-50 dark:bg-emerald-950/40 text-emerald-600 dark:text-emerald-400 flex items-center justify-center font-bold">
            <DollarSign className="w-6 h-6" />
          </div>
          <div>
            <div className="text-sm text-slate-500 font-medium">Earnings Allowances</div>
            <div className="text-2xl font-bold text-slate-900 dark:text-slate-100">
              {components.filter((c) => c.component_type === 'earning').length}
            </div>
          </div>
        </div>

        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm flex items-center gap-4">
          <div className="w-12 h-12 rounded-lg bg-rose-50 dark:bg-rose-950/40 text-rose-600 dark:text-rose-400 flex items-center justify-center font-bold">
            <TrendingDown className="w-6 h-6" />
          </div>
          <div>
            <div className="text-sm text-slate-500 font-medium">Statutory & Other Deductions</div>
            <div className="text-2xl font-bold text-slate-900 dark:text-slate-100">
              {components.filter((c) => c.component_type === 'deduction').length}
            </div>
          </div>
        </div>

        <div className="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 shadow-sm flex items-center gap-4">
          <div className="w-12 h-12 rounded-lg bg-indigo-50 dark:bg-indigo-950/40 text-indigo-600 dark:text-indigo-400 flex items-center justify-center font-bold">
            <Building2 className="w-6 h-6" />
          </div>
          <div>
            <div className="text-sm text-slate-500 font-medium">Employer Contributions</div>
            <div className="text-2xl font-bold text-slate-900 dark:text-slate-100">
              {components.filter((c) => c.component_type === 'employer_contribution').length}
            </div>
          </div>
        </div>
      </div>

      {/* Components Table */}
      <div className="rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 overflow-hidden shadow-sm">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 dark:border-slate-800 bg-slate-50/75 dark:bg-slate-800/50 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                <th className="py-3.5 px-4">Code & Name</th>
                <th className="py-3.5 px-4">Type</th>
                <th className="py-3.5 px-4">Formula / Calculation</th>
                <th className="py-3.5 px-4">Taxability</th>
                <th className="py-3.5 px-4">Absence Proration</th>
                <th className="py-3.5 px-4">Effective Date</th>
                <th className="py-3.5 px-4 text-right">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200 dark:divide-slate-800 text-sm">
              {components.length === 0 ? (
                <tr>
                  <td colSpan={7} className="py-8 text-center text-slate-500 dark:text-slate-400">
                    No salary components configured yet. Default templates will be automatically applied on first payroll run.
                  </td>
                </tr>
              ) : (
                components.map((c) => (
                  <tr key={c.id} className="hover:bg-slate-50/50 dark:hover:bg-slate-800/30 transition-colors">
                    <td className="py-3.5 px-4 font-medium text-slate-900 dark:text-slate-100">
                      <div className="flex items-center gap-2">
                        <span className="font-mono text-xs font-semibold px-2 py-0.5 rounded bg-slate-100 dark:bg-slate-800 text-slate-700 dark:text-slate-300">
                          {c.code}
                        </span>
                        <span>{c.name_en}</span>
                        {c.name_ur && (
                          <span className="text-xs text-slate-400 font-normal" dir="rtl">
                            ({c.name_ur})
                          </span>
                        )}
                      </div>
                    </td>
                    <td className="py-3.5 px-4">
                      {getTypeBadge(c.component_type)}
                    </td>
                    <td className="py-3.5 px-4 text-slate-600 dark:text-slate-300">
                      {c.calc_method === 'fixed_paisa' ? (
                        <span>{formatPkr(c.calc_value_paisa)} <span className="text-xs text-slate-400">(Fixed)</span></span>
                      ) : c.calc_method === 'pct_of_basic' ? (
                        <span className="flex items-center gap-1">
                          <Percent className="w-3.5 h-3.5 text-blue-500" />
                          {c.calc_pct}% of Basic
                        </span>
                      ) : (
                        <span className="flex items-center gap-1">
                          <Percent className="w-3.5 h-3.5 text-purple-500" />
                          {c.calc_pct}% of Gross
                        </span>
                      )}
                    </td>
                    <td className="py-3.5 px-4">
                      {c.is_taxable ? (
                        <div className="flex items-center gap-1.5 text-slate-700 dark:text-slate-300">
                          <CheckCircle className="w-4 h-4 text-amber-500" />
                          <span>Taxable</span>
                          {c.exemption_cap_pct > 0 && (
                            <span className="text-xs text-slate-400">({c.exemption_cap_pct}% exempt)</span>
                          )}
                        </div>
                      ) : (
                        <div className="flex items-center gap-1.5 text-slate-400">
                          <XCircle className="w-4 h-4 text-slate-400" />
                          <span>Exempt</span>
                        </div>
                      )}
                    </td>
                    <td className="py-3.5 px-4">
                      {c.prorates_on_absence ? (
                        <Badge variant="outline" className="text-emerald-700 border-emerald-300 dark:border-emerald-700/50">
                          Prorates
                        </Badge>
                      ) : (
                        <Badge variant="outline" className="text-slate-500 border-slate-300 dark:border-slate-700">
                          Fixed
                        </Badge>
                      )}
                    </td>
                    <td className="py-3.5 px-4 text-slate-500 font-mono text-xs">
                      {c.effective_from}
                    </td>
                    <td className="py-3.5 px-4 text-right">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => openEditModal(c)}
                        className="h-8 w-8 p-0 text-slate-500 hover:text-slate-900 dark:hover:text-slate-100"
                      >
                        <Edit2 className="w-4 h-4" />
                      </Button>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Create / Edit Modal */}
      <Modal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        title={selectedComp ? `Edit Component: ${selectedComp.code}` : 'Add Salary Component'}
        description="Define calculation parameters, taxability, and attendance deduction rules."
      >
        <form onSubmit={handleSubmit} className="space-y-4 pt-2">
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="code">Component Code *</Label>
              <Input
                id="code"
                name="code"
                placeholder="e.g. BASIC, CONVEYANCE"
                defaultValue={selectedComp?.code || ''}
                required
                className="font-mono uppercase"
              />
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="component_type">Component Category</Label>
              <select
                id="component_type"
                value={componentType}
                onChange={(e) => setComponentType(e.target.value as any)}
                className="w-full h-10 px-3 rounded-md border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 text-sm"
              >
                <option value="earning">Earning Allowance</option>
                <option value="deduction">Deduction</option>
                <option value="employer_contribution">Employer Contribution</option>
              </select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="name_en">Name (English) *</Label>
              <Input
                id="name_en"
                name="name_en"
                placeholder="e.g. Conveyance Allowance"
                defaultValue={selectedComp?.name_en || ''}
                required
              />
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="name_ur">Name (Urdu)</Label>
              <Input
                id="name_ur"
                name="name_ur"
                placeholder="e.g. سواری الاؤنس"
                defaultValue={selectedComp?.name_ur || ''}
                dir="rtl"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="calc_method">Calculation Method</Label>
              <select
                id="calc_method"
                value={calcMethod}
                onChange={(e) => setCalcMethod(e.target.value as any)}
                className="w-full h-10 px-3 rounded-md border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 text-sm"
              >
                <option value="fixed_paisa">Fixed Amount (PKR)</option>
                <option value="pct_of_basic">Percentage of Basic Salary</option>
                <option value="pct_of_gross">Percentage of Gross Salary</option>
              </select>
            </div>

            <div className="space-y-1.5">
              {calcMethod === 'fixed_paisa' ? (
                <>
                  <Label htmlFor="calc_value_pkr">Fixed Value (PKR)</Label>
                  <Input
                    id="calc_value_pkr"
                    name="calc_value_pkr"
                    type="number"
                    min="0"
                    step="1"
                    placeholder="e.g. 5000"
                    defaultValue={selectedComp ? selectedComp.calc_value_paisa / 100 : 0}
                  />
                </>
              ) : (
                <>
                  <Label htmlFor="calc_pct">Percentage Rate (%)</Label>
                  <Input
                    id="calc_pct"
                    name="calc_pct"
                    type="number"
                    min="0"
                    max="100"
                    step="0.01"
                    placeholder="e.g. 45.0"
                    defaultValue={selectedComp?.calc_pct || 0}
                  />
                </>
              )}
            </div>
          </div>

          <div className="border-t border-slate-200 dark:border-slate-800 pt-4 space-y-3">
            <div className="flex items-center justify-between">
              <div>
                <Label htmlFor="is_taxable" className="font-medium cursor-pointer">Subject to Income Tax</Label>
                <p className="text-xs text-slate-500">Include this component in employee taxable gross income.</p>
              </div>
              <input
                id="is_taxable"
                type="checkbox"
                checked={isTaxable}
                onChange={(e) => setIsTaxable(e.target.checked)}
                className="w-4 h-4 rounded text-blue-600 focus:ring-blue-500 cursor-pointer"
              />
            </div>

            {isTaxable && (
              <div className="space-y-1.5 pl-4 border-l-2 border-slate-200 dark:border-slate-800">
                <Label htmlFor="exemption_cap_pct">Tax Exemption Cap (%)</Label>
                <Input
                  id="exemption_cap_pct"
                  name="exemption_cap_pct"
                  type="number"
                  min="0"
                  max="100"
                  step="0.1"
                  placeholder="e.g. 100 for fully exempt allowances like Medical"
                  defaultValue={selectedComp?.exemption_cap_pct || 0}
                />
              </div>
            )}

            <div className="flex items-center justify-between pt-2">
              <div>
                <Label htmlFor="prorates_on_absence" className="font-medium cursor-pointer">Prorate on Unpaid Absence</Label>
                <p className="text-xs text-slate-500">Deduct proportionally when an employee has unpaid absence days.</p>
              </div>
              <input
                id="prorates_on_absence"
                type="checkbox"
                checked={prorates}
                onChange={(e) => setProrates(e.target.checked)}
                className="w-4 h-4 rounded text-blue-600 focus:ring-blue-500 cursor-pointer"
              />
            </div>
          </div>

          <div className="space-y-1.5 pt-2">
            <Label htmlFor="effective_from">Effective From Date</Label>
            <Input
              id="effective_from"
              name="effective_from"
              type="date"
              defaultValue={selectedComp?.effective_from || new Date().toISOString().slice(0, 10)}
              required
            />
          </div>

          <div className="flex justify-end gap-2 pt-4 border-t border-slate-200 dark:border-slate-800">
            <Button
              type="button"
              variant="outline"
              onClick={() => setModalOpen(false)}
              disabled={isPending}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={isPending}>
              {isPending ? 'Saving...' : selectedComp ? 'Update Component' : 'Save Component'}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
