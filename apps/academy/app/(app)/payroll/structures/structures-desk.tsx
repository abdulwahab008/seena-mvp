'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  EmployeeSalaryStructureRow,
  saveEmployeeSalaryStructure,
  ActionState,
} from '../actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Modal } from '@/components/ui/modal';
import {
  Plus,
  Search,
  CheckCircle2,
  Calendar,
  DollarSign,
  UserCheck,
} from 'lucide-react';

interface Props {
  initialStructures: EmployeeSalaryStructureRow[];
  staffList: Array<{ id: string; name: string; code: string }>;
}

export function StructuresDesk({ initialStructures, staffList }: Props) {
  const router = useRouter();
  const [structures] = useState<EmployeeSalaryStructureRow[]>(initialStructures);
  const [search, setSearch] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const [isPending, startTransition] = useTransition();

  const filtered = structures.filter(
    (s) =>
      s.staff_name.toLowerCase().includes(search.toLowerCase()) ||
      s.employee_code.toLowerCase().includes(search.toLowerCase())
  );

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const formData = new FormData(e.currentTarget);

    startTransition(async () => {
      const res: ActionState = await saveEmployeeSalaryStructure({ error: null }, formData);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Salary structure revision saved.');
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

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 pb-4 border-b border-slate-200 dark:border-slate-800">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Employee Salary Structures
          </h1>
          <p className="text-sm text-slate-500 dark:text-slate-400 mt-1">
            Maintain effective-dated compensation revisions with non-overlapping GiST validity history.
          </p>
        </div>
        <Button onClick={() => setModalOpen(true)} className="gap-2 shadow-sm">
          <Plus className="w-4 h-4" />
          Assign / Revise Salary Structure
        </Button>
      </div>

      {/* Search & Filter Bar */}
      <div className="flex items-center gap-4">
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-slate-400" />
          <Input
            placeholder="Search by employee name or code..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9 bg-white dark:bg-slate-900"
          />
        </div>
      </div>

      {/* Structures Table */}
      <div className="rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 overflow-hidden shadow-sm">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 dark:border-slate-800 bg-slate-50/75 dark:bg-slate-800/50 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                <th className="py-3.5 px-4">Employee</th>
                <th className="py-3.5 px-4">Basic Salary</th>
                <th className="py-3.5 px-4">Effective Validity Window</th>
                <th className="py-3.5 px-4">Component Overrides</th>
                <th className="py-3.5 px-4">Status</th>
                <th className="py-3.5 px-4">Approval</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200 dark:divide-slate-800 text-sm">
              {filtered.length === 0 ? (
                <tr>
                  <td colSpan={6} className="py-8 text-center text-slate-500 dark:text-slate-400">
                    No employee salary structures found. Click &quot;Assign / Revise Salary Structure&quot; to configure compensation.
                  </td>
                </tr>
              ) : (
                filtered.map((s) => (
                  <tr key={s.id} className="hover:bg-slate-50/50 dark:hover:bg-slate-800/30 transition-colors">
                    <td className="py-3.5 px-4">
                      <div>
                        <div className="font-semibold text-slate-900 dark:text-slate-100 flex items-center gap-2">
                          <UserCheck className="w-4 h-4 text-blue-500" />
                          {s.staff_name}
                        </div>
                        <div className="text-xs font-mono text-slate-400">{s.employee_code}</div>
                      </div>
                    </td>
                    <td className="py-3.5 px-4">
                      <div className="font-semibold text-slate-900 dark:text-slate-100 flex items-center gap-1">
                        <DollarSign className="w-3.5 h-3.5 text-emerald-600" />
                        {formatPkr(s.basic_paisa)}
                        <span className="text-xs font-normal text-slate-400">/mo</span>
                      </div>
                    </td>
                    <td className="py-3.5 px-4">
                      <div className="flex items-center gap-1.5 font-mono text-xs text-slate-600 dark:text-slate-300">
                        <Calendar className="w-3.5 h-3.5 text-slate-400" />
                        <span>{s.start_date}</span>
                        <span className="text-slate-400">&rarr;</span>
                        <span>{s.end_date || 'Open-ended'}</span>
                      </div>
                    </td>
                    <td className="py-3.5 px-4">
                      {Object.keys(s.component_overrides || {}).length > 0 ? (
                        <div className="flex flex-wrap gap-1">
                          {Object.entries(s.component_overrides).map(([k, v]) => (
                            <Badge key={k} variant="default" className="font-mono text-xs">
                              {k}: {formatPkr(v as number)}
                            </Badge>
                          ))}
                        </div>
                      ) : (
                        <span className="text-xs text-slate-400 italic">Standard catalog formulas</span>
                      )}
                    </td>
                    <td className="py-3.5 px-4">
                      {!s.end_date || new Date(s.end_date) >= new Date() ? (
                        <Badge variant="default" className="bg-emerald-600">Active</Badge>
                      ) : (
                        <Badge variant="outline" className="text-slate-400">Expired</Badge>
                      )}
                    </td>
                    <td className="py-3.5 px-4 text-xs text-slate-500">
                      {s.approved_at ? (
                        <div className="flex items-center gap-1 text-emerald-600 dark:text-emerald-400">
                          <CheckCircle2 className="w-3.5 h-3.5" />
                          <span>Approved</span>
                        </div>
                      ) : (
                        <span className="text-amber-500">Draft</span>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Modal: Assign / Revise Salary Structure */}
      <Modal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        title="Assign or Revise Salary Structure"
        description="Creates an effective-dated compensation record. GiST constraints will ensure non-overlapping historical validity."
      >
        <form onSubmit={handleSubmit} className="space-y-4 pt-2">
          <div className="space-y-1.5">
            <Label htmlFor="staff_id">Select Employee *</Label>
            <select
              id="staff_id"
              name="staff_id"
              required
              className="w-full h-10 px-3 rounded-md border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 text-sm"
            >
              <option value="">-- Choose a staff member --</option>
              {staffList.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name} ({s.code})
                </option>
              ))}
            </select>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="basic_pkr">Basic Monthly Salary (PKR) *</Label>
            <Input
              id="basic_pkr"
              name="basic_pkr"
              type="number"
              min="1"
              step="1"
              placeholder="e.g. 80000"
              required
            />
            <p className="text-xs text-slate-500">
              Basic salary is the base upon which House Rent (45%) and Medical (10%) allowances are calculated.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="start_date">Effective Start Date *</Label>
              <Input
                id="start_date"
                name="start_date"
                type="date"
                defaultValue={new Date().toISOString().slice(0, 10)}
                required
              />
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="end_date">Effective End Date</Label>
              <Input
                id="end_date"
                name="end_date"
                type="date"
                placeholder="Leave blank for open-ended"
              />
            </div>
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
              {isPending ? 'Saving...' : 'Save Structure Revision'}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
