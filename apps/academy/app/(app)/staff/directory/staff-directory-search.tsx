'use client';

import { useState, useEffect, useTransition, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { Building2, Filter, Pencil } from 'lucide-react';
import { searchStaffDirectory, type StaffDirectoryRow } from './actions';
import { searchStaffSchema, type SearchStaffInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { assignStaffDepartmentAction } from '../departments/actions';

export interface DepartmentFilterItem {
  id: string;
  name_en: string;
  code: string;
}

export function StaffDirectorySearch({
  initialResults,
  departments = [],
}: {
  initialResults: StaffDirectoryRow[];
  departments?: DepartmentFilterItem[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [results, setResults] = useState<StaffDirectoryRow[]>(initialResults);
  const [selectedDeptFilter, setSelectedDeptFilter] = useState<string>('all');
  const [reassignModalStaff, setReassignModalStaff] = useState<StaffDirectoryRow | null>(null);
  const [reassignDeptId, setReassignDeptId] = useState<string>('');

  // 1. Synchronize when Server Component updates initialResults
  useEffect(() => {
    setResults(initialResults);
  }, [initialResults]);

  // 2. Reactive listener for staff registration/updates to trigger instant refresh
  const refreshDirectory = useCallback(() => {
    startTransition(async () => {
      const fd = new FormData();
      const result = await searchStaffDirectory({ error: null, results: null }, fd);
      if (!result.error && result.results) {
        setResults(result.results);
      }
    });
  }, []);

  useEffect(() => {
    const handleStaffUpdated = () => {
      refreshDirectory();
    };

    window.addEventListener('staff-directory-updated', handleStaffUpdated);
    return () => {
      window.removeEventListener('staff-directory-updated', handleStaffUpdated);
    };
  }, [refreshDirectory]);

  const { register, handleSubmit } = useForm<SearchStaffInput>({ resolver: zodResolver(searchStaffSchema) });

  const onSearch = handleSubmit((values) => {
    const fd = new FormData();
    if (values.q) fd.set('q', values.q);
    if (values.includeFormer) fd.set('includeFormer', 'on');

    startTransition(async () => {
      const result = await searchStaffDirectory({ error: null, results: null }, fd);
      if (result.error) toast.error(result.error);
      else setResults(result.results ?? []);
    });
  });

  const handleSaveReassignment = async () => {
    if (!reassignModalStaff) return;

    startTransition(async () => {
      const targetDeptId = reassignDeptId === 'none' || !reassignDeptId ? null : reassignDeptId;
      const res = await assignStaffDepartmentAction(reassignModalStaff.staff_id, targetDeptId);
      if (res.error) {
        toast.error(res.error);
      } else {
        const deptObj = departments.find((d) => d.id === targetDeptId);
        const newDeptName = deptObj ? deptObj.name_en : null;
        toast.success(`Updated department for ${reassignModalStaff.full_name}`);
        setResults((prev) =>
          prev.map((row) =>
            row.staff_id === reassignModalStaff.staff_id ? { ...row, department: newDeptName } : row
          )
        );
        setReassignModalStaff(null);
        router.refresh();
      }
    });
  };

  const filteredResults =
    selectedDeptFilter === 'all'
      ? results
      : selectedDeptFilter === 'unassigned'
      ? results.filter((r) => !r.department)
      : results.filter((r) => r.department === selectedDeptFilter);

  return (
    <div className="space-y-4">
      {/* Search & Filters */}
      <form onSubmit={onSearch} className="flex flex-wrap items-end gap-3 rounded-lg border p-4 bg-card" noValidate>
        <div className="flex-1 min-w-[220px] space-y-1">
          <Label htmlFor="q">Search Directory</Label>
          <Input id="q" data-testid="staff-directory-query" placeholder="Name or employee code" {...register('q')} />
        </div>

        {/* Department Filter */}
        {departments.length > 0 && (
          <div className="min-w-[200px] space-y-1">
            <Label htmlFor="dept-filter" className="flex items-center gap-1.5">
              <Filter className="h-3.5 w-3.5 text-muted-foreground" />
              Filter by Department
            </Label>
            <select
              id="dept-filter"
              value={selectedDeptFilter}
              onChange={(e) => setSelectedDeptFilter(e.target.value)}
              className="w-full rounded-md border bg-background px-3 py-2 text-sm shadow-sm focus:outline-none focus:ring-2 focus:ring-primary"
              data-testid="staff-department-filter"
            >
              <option value="all">All Departments ({results.length})</option>
              <option value="unassigned">Unassigned Department</option>
              {departments.map((dept) => (
                <option key={dept.id} value={dept.name_en}>
                  {dept.code} — {dept.name_en}
                </option>
              ))}
            </select>
          </div>
        )}

        <label className="flex items-center gap-2 pb-2 text-sm">
          <input type="checkbox" data-testid="staff-directory-include-former" {...register('includeFormer')} />
          Include former staff
        </label>
        <Button type="submit" disabled={pending} data-testid="staff-directory-search-button">
          {pending ? 'Searching…' : 'Search'}
        </Button>
      </form>

      {/* Results Table */}
      <div className="rounded-lg border bg-card overflow-x-auto shadow-sm">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground bg-muted/40">
              <th className="p-3">Faculty / Staff Name</th>
              <th className="p-3">Employee Code</th>
              <th className="p-3">Designation</th>
              <th className="p-3">Academic Department</th>
              <th className="p-3">Status</th>
              <th className="p-3">Mobile Contact</th>
              <th className="p-3">CNIC / ID</th>
              <th className="p-3 text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {filteredResults.map((r) => (
              <tr
                key={r.staff_id}
                data-testid={`staff-directory-row-${r.full_name}`}
                className="border-b last:border-0 hover:bg-muted/20 transition-colors"
              >
                <td className="p-3 font-medium">
                  <Link href={`/staff/${r.staff_id}`} className="hover:underline" data-testid={`staff-profile-link-${r.full_name}`}>
                    {r.full_name}
                  </Link>
                  {r.is_former && (
                    <span
                      className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground"
                      data-testid={`staff-directory-former-${r.full_name}`}
                    >
                      former
                    </span>
                  )}
                </td>
                <td className="p-3 font-mono text-xs">{r.employee_code}</td>
                <td className="p-3">{r.designation ?? '—'}</td>
                <td className="p-3" data-testid={`staff-dept-${r.full_name}`}>
                  {r.department ? (
                    <span className="inline-flex items-center gap-1.5 rounded-md bg-indigo-50 dark:bg-indigo-950/50 px-2.5 py-1 text-xs font-semibold text-indigo-700 dark:text-indigo-300 border border-indigo-200 dark:border-indigo-800">
                      <Building2 className="h-3 w-3" />
                      {r.department}
                    </span>
                  ) : (
                    <span className="text-xs text-muted-foreground italic">Unassigned</span>
                  )}
                </td>
                <td className="p-3">
                  <span
                    className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${
                      r.employment_status === 'active'
                        ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300'
                        : 'bg-muted text-muted-foreground'
                    }`}
                  >
                    {r.employment_status}
                  </span>
                </td>
                <td className="p-3 font-mono text-xs" data-testid={`staff-directory-mobile-${r.full_name}`}>
                  {r.mobile ?? '—'}
                </td>
                <td className="p-3 font-mono text-xs" data-testid={`staff-directory-idnum-${r.full_name}`}>
                  {r.identity_document_number ?? '—'}
                </td>
                <td className="p-3 text-right">
                  <button
                    type="button"
                    onClick={() => {
                      setReassignModalStaff(r);
                      const currentDept = departments.find((d) => d.name_en === r.department);
                      setReassignDeptId(currentDept ? currentDept.id : 'none');
                    }}
                    className="inline-flex items-center gap-1 rounded px-2 py-1 text-xs font-medium text-primary hover:bg-primary/10 transition-colors"
                    title="Change Department"
                    data-testid={`edit-dept-btn-${r.employee_code}`}
                  >
                    <Pencil className="h-3 w-3" />
                    Dept
                  </button>
                </td>
              </tr>
            ))}
            {filteredResults.length === 0 && (
              <tr>
                <td className="p-4 text-center text-muted-foreground" colSpan={8}>
                  No staff found.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {/* Quick Reassign Department In-App Modal */}
      <Modal
        open={Boolean(reassignModalStaff)}
        onClose={() => setReassignModalStaff(null)}
        title="Change Academic Department"
        description={
          reassignModalStaff ? (
            <>
              Select academic department for{' '}
              <span className="font-semibold text-foreground">{reassignModalStaff.full_name}</span>.
            </>
          ) : undefined
        }
        size="sm"
      >
        <div className="space-y-4 py-1">
          <div className="space-y-1.5">
            <Label htmlFor="reassign-dept-select">Department</Label>
            <select
              id="reassign-dept-select"
              value={reassignDeptId}
              onChange={(e) => setReassignDeptId(e.target.value)}
              className="w-full rounded-md border bg-background px-3 py-2 text-sm shadow-sm focus:outline-none focus:ring-2 focus:ring-primary"
              data-testid="reassign-dept-select"
            >
              <option value="none">-- No Department (Unassigned) --</option>
              {departments.map((dept) => (
                <option key={dept.id} value={dept.id}>
                  {dept.code} — {dept.name_en}
                </option>
              ))}
            </select>
          </div>

          <div className="flex justify-end gap-2 pt-3 border-t">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => setReassignModalStaff(null)}
              disabled={pending}
            >
              Cancel
            </Button>
            <Button
              type="button"
              size="sm"
              onClick={handleSaveReassignment}
              disabled={pending}
              data-testid="confirm-reassign-dept-btn"
            >
              {pending ? 'Saving…' : 'Save Department'}
            </Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
