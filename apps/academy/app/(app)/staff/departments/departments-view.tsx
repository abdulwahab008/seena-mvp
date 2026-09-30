'use client';

import { useState, useEffect, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  Plus,
  Pencil,
  Trash2,
  GraduationCap,
  AlertCircle,
  X,
  Loader2,
  Search,
  LayoutGrid,
  List,
  Check,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal, ConfirmDialog } from '@/components/ui/modal';
import {
  upsertDepartmentAction,
  deleteDepartmentAction,
  assignStaffDepartmentAction,
  getUnassignedStaffAction,
} from './actions';

function getInitials(name: string): string {
  const parts = name.trim().split(/\s+/);
  const first = parts[0];
  if (!first) return '??';
  const last = parts[parts.length - 1];
  if (parts.length === 1 || !last) return first.slice(0, 2).toUpperCase();
  return ((first[0] ?? '') + (last[0] ?? '')).toUpperCase();
}

export type DepartmentItem = {
  id: string;
  code: string;
  name_en: string;
  name_ur: string | null;
  teacherCount: number;
  teachers: { id: string; employee_code: string; full_name: string; role?: string }[];
};

export type UnassignedStaffItem = {
  id: string;
  employee_code: string;
  full_name: string;
};

export function DepartmentsView({
  departments,
  unassignedStaff,
}: {
  departments: DepartmentItem[];
  unassignedStaff: UnassignedStaffItem[];
}) {
  const router = useRouter();
  const [deptList, setDeptList] = useState<DepartmentItem[]>(departments);
  const [unassignedList, setUnassignedList] = useState<UnassignedStaffItem[]>(unassignedStaff);
  const [loadingUnassigned, setLoadingUnassigned] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [viewMode, setViewMode] = useState<'grid' | 'table'>('grid');
  const [facultySearch, setFacultySearch] = useState('');

  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [editingDept, setEditingDept] = useState<DepartmentItem | null>(null);
  const [assignModalDept, setAssignModalDept] = useState<DepartmentItem | null>(null);
  const [selectedStaffId, setSelectedStaffId] = useState('');
  const [deptToDelete, setDeptToDelete] = useState<DepartmentItem | null>(null);
  const [staffToUnassign, setStaffToUnassign] = useState<{ id: string; name: string } | null>(null);
  const [pending, startTransition] = useTransition();

  // Sync state whenever server props revalidate
  useEffect(() => {
    setDeptList(departments);
  }, [departments]);

  useEffect(() => {
    setUnassignedList(unassignedStaff);
  }, [unassignedStaff]);

  // Listen for staff created / updated events across the app and refresh live unassigned faculty
  useEffect(() => {
    const handleStaffUpdated = async () => {
      router.refresh();
      try {
        const res = await getUnassignedStaffAction();
        if (res.data) {
          setUnassignedList(res.data);
        }
      } catch (err) {
        console.error('Failed to reload unassigned staff:', err);
      }
    };

    window.addEventListener('staff-directory-updated', handleStaffUpdated);
    return () => {
      window.removeEventListener('staff-directory-updated', handleStaffUpdated);
    };
  }, [router]);

  // Open Assign Modal and fetch real-time fresh unassigned faculty
  const openAssignModal = async (dept: DepartmentItem) => {
    setAssignModalDept(dept);
    setSelectedStaffId('');
    setFacultySearch('');
    setLoadingUnassigned(true);
    try {
      const res = await getUnassignedStaffAction();
      if (res.data) {
        setUnassignedList(res.data);
      }
    } catch (err) {
      console.error('Failed to load fresh unassigned staff:', err);
    } finally {
      setLoadingUnassigned(false);
    }
  };

  // Create or Update Department (in-app modal form with instant state update)
  const handleSaveDepartment = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    if (editingDept) {
      fd.set('id', editingDept.id);
    }

    startTransition(async () => {
      const res = await upsertDepartmentAction(fd);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(editingDept ? 'Department updated successfully.' : 'Department created successfully.');
        setIsCreateOpen(false);
        if (res.data) {
          const updated = res.data;
          setDeptList((prev) => {
            const exists = prev.some((d) => d.id === updated.id);
            if (exists) {
              return prev.map((d) =>
                d.id === updated.id
                  ? {
                      ...d,
                      code: updated.code,
                      name_en: updated.name_en,
                      name_ur: updated.name_ur !== undefined ? updated.name_ur : d.name_ur,
                    }
                  : d
              );
            } else {
              return [
                ...prev,
                {
                  id: updated.id,
                  code: updated.code,
                  name_en: updated.name_en,
                  name_ur: updated.name_ur ?? null,
                  teacherCount: 0,
                  teachers: [],
                },
              ];
            }
          });
        }
        setEditingDept(null);
        router.refresh();
      }
    });
  };

  // Delete Department - opens in-app confirmation modal
  const handleDeleteDepartment = (dept: DepartmentItem) => {
    if (dept.teacherCount > 0) {
      toast.error(`Cannot delete ${dept.name_en}. Reassign its ${dept.teacherCount} teachers first.`);
      return;
    }
    setDeptToDelete(dept);
  };

  const confirmDeleteDepartment = () => {
    if (!deptToDelete) return;

    startTransition(async () => {
      const res = await deleteDepartmentAction(deptToDelete.id);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(`Department "${deptToDelete.name_en}" removed.`);
        setDeptList((prev) => prev.filter((d) => d.id !== deptToDelete.id));
        setDeptToDelete(null);
        router.refresh();
      }
    });
  };

  // Assign Staff to Department
  const handleAssignStaff = async () => {
    if (!assignModalDept || !selectedStaffId) return;

    const currentDept = deptList.find((d) => d.id === assignModalDept.id) ?? assignModalDept;
    const targetDeptId = currentDept.id;
    const targetDeptName = currentDept.name_en;
    const staffObj = unassignedList.find((s) => s.id === selectedStaffId);

    startTransition(async () => {
      const res = await assignStaffDepartmentAction(selectedStaffId, targetDeptId);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(`Faculty member assigned to ${targetDeptName}.`);
        if (staffObj) {
          setDeptList((prev) =>
            prev.map((d) =>
              d.id === targetDeptId
                ? {
                    ...d,
                    teacherCount: d.teacherCount + 1,
                    teachers: [
                      ...d.teachers,
                      {
                        id: staffObj.id,
                        employee_code: staffObj.employee_code,
                        full_name: staffObj.full_name,
                      },
                    ],
                  }
                : d
            )
          );
          setUnassignedList((prev) => prev.filter((s) => s.id !== selectedStaffId));
        }
        setAssignModalDept(null);
        setSelectedStaffId('');
        router.refresh();
      }
    });
  };

  // Unassign Staff from Department - opens in-app confirmation modal
  const handleUnassignStaff = (staffId: string, staffName: string) => {
    setStaffToUnassign({ id: staffId, name: staffName });
  };

  const confirmUnassignStaff = () => {
    if (!staffToUnassign) return;

    const unassignId = staffToUnassign.id;
    const unassignName = staffToUnassign.name;

    startTransition(async () => {
      const res = await assignStaffDepartmentAction(unassignId, null);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(`${unassignName} unassigned from department.`);
        setDeptList((prev) =>
          prev.map((d) => {
            const hasTeacher = d.teachers.some((t) => t.id === unassignId);
            if (!hasTeacher) return d;
            const teacher = d.teachers.find((t) => t.id === unassignId);
            if (teacher) {
              setUnassignedList((uPrev) => [
                ...uPrev,
                {
                  id: teacher.id,
                  employee_code: teacher.employee_code,
                  full_name: teacher.full_name,
                },
              ]);
            }
            return {
              ...d,
              teacherCount: Math.max(0, d.teacherCount - 1),
              teachers: d.teachers.filter((t) => t.id !== unassignId),
            };
          })
        );
        setStaffToUnassign(null);
        router.refresh();
      }
    });
  };

  const totalAssigned = deptList.reduce((acc, d) => acc + d.teacherCount, 0);

  const filteredDepts = deptList.filter((d) => {
    if (!searchQuery.trim()) return true;
    const q = searchQuery.toLowerCase();
    return (
      d.name_en.toLowerCase().includes(q) ||
      d.code.toLowerCase().includes(q) ||
      d.teachers.some(
        (t) =>
          t.full_name.toLowerCase().includes(q) ||
          t.employee_code.toLowerCase().includes(q)
      )
    );
  });

  const filteredUnassigned = unassignedList.filter((s) => {
    if (!facultySearch.trim()) return true;
    const q = facultySearch.toLowerCase();
    return (
      s.full_name.toLowerCase().includes(q) ||
      s.employee_code.toLowerCase().includes(q)
    );
  });

  return (
    <div className="space-y-6">
      {/* Unified Minimal Header & Stats */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between border-b pb-4">
        <div>
          <div className="flex items-center gap-3">
            <h1 className="text-2xl font-bold tracking-tight">Academic Departments</h1>
            <span className="inline-flex items-center rounded-full bg-primary/10 px-2.5 py-0.5 text-xs font-semibold text-primary">
              {deptList.length} Active
            </span>
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
            <span className="inline-flex items-center gap-1.5 font-medium text-foreground/80">
              <span className="h-2 w-2 rounded-full bg-emerald-500" />
              {totalAssigned} Assigned Faculty
            </span>
            <span className="text-muted-foreground/40">•</span>
            <span className="inline-flex items-center gap-1.5 font-medium text-foreground/80">
              <span className="h-2 w-2 rounded-full bg-amber-500" />
              {unassignedList.length} Unassigned Staff
            </span>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          {/* Quick Search */}
          <div className="relative w-full sm:w-56">
            <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
            <Input
              placeholder="Search departments..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="pl-8 h-9 text-xs"
            />
          </div>

          {/* View Toggle */}
          <div className="flex items-center rounded-lg border bg-muted/40 p-0.5">
            <button
              type="button"
              onClick={() => setViewMode('grid')}
              className={`rounded-md p-1.5 transition-colors ${
                viewMode === 'grid'
                  ? 'bg-background text-foreground shadow-xs'
                  : 'text-muted-foreground hover:text-foreground'
              }`}
              title="Grid View"
            >
              <LayoutGrid className="h-4 w-4" />
            </button>
            <button
              type="button"
              onClick={() => setViewMode('table')}
              className={`rounded-md p-1.5 transition-colors ${
                viewMode === 'table'
                  ? 'bg-background text-foreground shadow-xs'
                  : 'text-muted-foreground hover:text-foreground'
              }`}
              title="Table View"
            >
              <List className="h-4 w-4" />
            </button>
          </div>

          <Button
            onClick={() => {
              setEditingDept(null);
              setIsCreateOpen(true);
            }}
            className="gap-1.5 h-9 text-xs"
            data-testid="add-department-button"
          >
            <Plus className="h-4 w-4" />
            + New Department
          </Button>
        </div>
      </div>

      {/* Departments Content */}
      {filteredDepts.length === 0 ? (
        <div className="rounded-xl border border-dashed p-10 text-center text-sm text-muted-foreground">
          No departments found matching &ldquo;{searchQuery}&rdquo;.
        </div>
      ) : viewMode === 'grid' ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {filteredDepts.map((dept) => (
            <div
              key={dept.id}
              data-testid={`department-card-${dept.code}`}
              className="group relative flex flex-col justify-between rounded-xl border bg-card p-4 transition-all hover:border-primary/40 hover:shadow-xs"
            >
              <div>
                <div className="flex items-start justify-between gap-2">
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="inline-flex shrink-0 items-center rounded-md bg-muted px-2 py-0.5 text-xs font-bold font-mono text-foreground/80">
                      {dept.code}
                    </span>
                    <h3 className="font-semibold text-sm text-foreground truncate" title={dept.name_en}>
                      {dept.name_en}
                    </h3>
                  </div>

                  <div className="flex items-center gap-0.5 shrink-0 opacity-80 group-hover:opacity-100 transition-opacity">
                    <button
                      type="button"
                      onClick={() => {
                        setEditingDept(dept);
                        setIsCreateOpen(true);
                      }}
                      className="rounded p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
                      title="Edit Department"
                    >
                      <Pencil className="h-3.5 w-3.5" />
                    </button>
                    <button
                      type="button"
                      disabled={dept.teacherCount > 0}
                      onClick={() => handleDeleteDepartment(dept)}
                      className="rounded p-1 text-muted-foreground hover:bg-red-50 hover:text-red-600 disabled:opacity-30 disabled:cursor-not-allowed"
                      title={dept.teacherCount > 0 ? 'Cannot delete with active faculty' : 'Delete Department'}
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                </div>

                {/* Faculty Section */}
                <div className="mt-3 border-t pt-2.5">
                  {dept.teachers.length > 0 ? (
                    <div>
                      <div className="flex items-center justify-between text-xs text-muted-foreground mb-2">
                        <span className="font-medium text-foreground/70">
                          Faculty ({dept.teacherCount})
                        </span>
                        <button
                          type="button"
                          data-testid={`assign-faculty-btn-${dept.code}`}
                          onClick={() => openAssignModal(dept)}
                          className="text-xs font-medium text-primary hover:underline"
                        >
                          + Assign
                        </button>
                      </div>

                      <div className="space-y-1.5 max-h-36 overflow-y-auto pr-1">
                        {dept.teachers.map((t) => (
                          <div
                            key={t.id}
                            className="flex items-center justify-between rounded-lg bg-muted/40 px-2.5 py-1.5 text-xs text-foreground transition-colors hover:bg-muted/70"
                          >
                            <div className="flex items-center gap-2 truncate">
                              <span className="font-mono text-[10px] text-muted-foreground">{t.employee_code}</span>
                              <span className="font-medium truncate">{t.full_name}</span>
                            </div>
                            <button
                              type="button"
                              onClick={() => handleUnassignStaff(t.id, t.full_name)}
                              className="ml-2 text-muted-foreground hover:text-destructive text-sm leading-none"
                              title="Remove from Department"
                            >
                              &times;
                            </button>
                          </div>
                        ))}
                      </div>
                    </div>
                  ) : (
                    <button
                      type="button"
                      data-testid={`assign-faculty-btn-${dept.code}`}
                      onClick={() => openAssignModal(dept)}
                      className="flex w-full items-center justify-center gap-1.5 rounded-lg border border-dashed border-border/80 py-2 text-xs font-medium text-muted-foreground hover:border-primary/50 hover:bg-primary/5 hover:text-primary transition-all"
                    >
                      <Plus className="h-3.5 w-3.5" />
                      Assign Faculty
                    </button>
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>
      ) : (
        /* Table View */
        <div className="rounded-xl border bg-card shadow-xs overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-left text-xs">
              <thead className="border-b bg-muted/40 text-muted-foreground uppercase font-medium">
                <tr>
                  <th className="px-4 py-3">Code</th>
                  <th className="px-4 py-3">Department</th>
                  <th className="px-4 py-3">Faculty Members</th>
                  <th className="px-4 py-3 text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border/50">
                {filteredDepts.map((dept) => (
                  <tr
                    key={dept.id}
                    data-testid={`department-card-${dept.code}`}
                    className="hover:bg-muted/30 transition-colors"
                  >
                    <td className="px-4 py-3">
                      <span className="inline-flex items-center rounded-md bg-muted px-2 py-0.5 font-mono text-xs font-bold text-foreground/80">
                        {dept.code}
                      </span>
                    </td>
                    <td className="px-4 py-3 font-semibold text-foreground">
                      {dept.name_en}
                    </td>
                    <td className="px-4 py-3">
                      {dept.teachers.length > 0 ? (
                        <div className="flex flex-wrap gap-1.5">
                          {dept.teachers.map((t) => (
                            <span
                              key={t.id}
                              className="inline-flex items-center gap-1 rounded-md bg-muted/60 px-2 py-0.5 text-xs text-foreground"
                            >
                              <span className="font-mono text-[10px] text-muted-foreground">{t.employee_code}</span>
                              <span className="truncate max-w-[140px]">{t.full_name}</span>
                              <button
                                type="button"
                                onClick={() => handleUnassignStaff(t.id, t.full_name)}
                                className="ml-0.5 text-muted-foreground hover:text-destructive"
                                title="Remove"
                              >
                                &times;
                              </button>
                            </span>
                          ))}
                        </div>
                      ) : (
                        <span className="text-muted-foreground/60 italic text-[11px]">Unassigned</span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <div className="flex items-center justify-end gap-1.5">
                        <button
                          type="button"
                          data-testid={`assign-faculty-btn-${dept.code}`}
                          onClick={() => openAssignModal(dept)}
                          className="rounded border border-primary/20 bg-primary/5 px-2 py-1 text-xs font-medium text-primary hover:bg-primary/10 transition-colors"
                        >
                          + Assign
                        </button>
                        <button
                          type="button"
                          onClick={() => {
                            setEditingDept(dept);
                            setIsCreateOpen(true);
                          }}
                          className="rounded p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
                          title="Edit"
                        >
                          <Pencil className="h-3.5 w-3.5" />
                        </button>
                        <button
                          type="button"
                          disabled={dept.teacherCount > 0}
                          onClick={() => handleDeleteDepartment(dept)}
                          className="rounded p-1 text-muted-foreground hover:bg-red-50 hover:text-red-600 disabled:opacity-30 disabled:cursor-not-allowed"
                          title={dept.teacherCount > 0 ? 'Cannot delete with faculty' : 'Delete'}
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Create / Edit Department Modal */}
      <Modal
        open={isCreateOpen}
        onClose={() => {
          setIsCreateOpen(false);
          setEditingDept(null);
        }}
        title={editingDept ? `Edit Department: ${editingDept.code}` : 'Create Academic Department'}
        description="Configure department code, title, and representation for school records."
        size="md"
      >
        <form onSubmit={handleSaveDepartment} className="space-y-4 py-1">
          <div className="space-y-1.5">
            <Label htmlFor="code">Department Code *</Label>
            <Input
              id="code"
              name="code"
              defaultValue={editingDept?.code ?? ''}
              placeholder="e.g. SCI, MATH, CS_IT, COMMERCE"
              required
              className="uppercase font-mono"
              data-testid="department-code-input"
            />
            <p className="text-[11px] text-muted-foreground">Unique alphanumeric code (2-10 chars).</p>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="nameEn">English Name *</Label>
            <Input
              id="nameEn"
              name="nameEn"
              defaultValue={editingDept?.name_en ?? ''}
              placeholder="e.g. Sciences, Mathematics, Commerce & Accounting"
              required
              data-testid="department-name-en-input"
            />
          </div>

          <div className="mt-6 flex justify-end gap-2 border-t pt-4">
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setIsCreateOpen(false);
                setEditingDept(null);
              }}
              disabled={pending}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={pending} data-testid="save-department-button">
              {pending ? 'Saving…' : editingDept ? 'Update Department' : 'Create Department'}
            </Button>
          </div>
        </form>
      </Modal>

      {/* Assign Faculty Modal */}
      <Modal
        open={Boolean(assignModalDept)}
        onClose={() => {
          setAssignModalDept(null);
          setSelectedStaffId('');
          setFacultySearch('');
        }}
        title="Assign Faculty Member"
        description={
          assignModalDept
            ? `Select an unassigned teacher to assign to ${(deptList.find((d) => d.id === assignModalDept.id) ?? assignModalDept).name_en}.`
            : ''
        }
        size="md"
      >
        <div className="space-y-3 py-1">
          {/* Quick Search inside modal */}
          <div className="relative">
            <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
            <Input
              placeholder="Search faculty by name or employee code..."
              value={facultySearch}
              onChange={(e) => setFacultySearch(e.target.value)}
              className="pl-8 h-9 text-xs"
            />
          </div>

          <div data-testid="assign-faculty-select" className="space-y-1.5">
            <div className="flex items-center justify-between text-xs font-medium text-muted-foreground px-0.5">
              <span>Available Unassigned Faculty ({filteredUnassigned.length})</span>
              {selectedStaffId && (
                <button
                  type="button"
                  onClick={() => setSelectedStaffId('')}
                  className="text-xs text-primary hover:underline font-normal"
                >
                  Clear Selection
                </button>
              )}
            </div>

            {loadingUnassigned ? (
              <div className="flex items-center justify-center gap-2 py-8 text-xs text-muted-foreground">
                <Loader2 className="h-4 w-4 animate-spin text-primary" />
                <span>Fetching latest faculty...</span>
              </div>
            ) : filteredUnassigned.length > 0 ? (
              <div className="max-h-56 overflow-y-auto space-y-1 rounded-lg border p-1">
                {filteredUnassigned.map((s) => {
                  const isSelected = selectedStaffId === s.id;
                  return (
                    <div
                      key={s.id}
                      onClick={() => setSelectedStaffId(s.id)}
                      className={`flex cursor-pointer items-center justify-between rounded-md px-2.5 py-2 transition-all ${
                        isSelected
                          ? 'bg-primary/10 border border-primary/40 text-foreground'
                          : 'hover:bg-muted/60 border border-transparent text-foreground/80'
                      }`}
                    >
                      <div className="flex items-center gap-2.5 min-w-0">
                        <div
                          className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-[11px] font-bold ${
                            isSelected
                              ? 'bg-primary text-primary-foreground'
                              : 'bg-muted text-muted-foreground'
                          }`}
                        >
                          {getInitials(s.full_name)}
                        </div>
                        <div className="truncate">
                          <p className="text-xs font-medium text-foreground truncate">{s.full_name}</p>
                          <p className="font-mono text-[10px] text-muted-foreground">{s.employee_code}</p>
                        </div>
                      </div>

                      {isSelected ? (
                        <Check className="h-4 w-4 text-primary shrink-0" />
                      ) : (
                        <span className="text-[11px] text-muted-foreground/60">Select</span>
                      )}
                    </div>
                  );
                })}
              </div>
            ) : (
              <div className="rounded-lg border border-dashed p-6 text-center text-xs text-muted-foreground">
                {unassignedList.length === 0
                  ? 'All active teachers are already assigned to departments.'
                  : 'No unassigned teachers match your search.'}
              </div>
            )}
          </div>

          <div className="mt-5 flex justify-end gap-2 border-t pt-3">
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setAssignModalDept(null);
                setSelectedStaffId('');
                setFacultySearch('');
              }}
              disabled={pending}
            >
              Cancel
            </Button>
            <Button
              type="button"
              onClick={handleAssignStaff}
              disabled={!selectedStaffId || pending || loadingUnassigned}
              data-testid="confirm-assign-faculty-button"
            >
              {pending ? 'Assigning…' : 'Assign to Department'}
            </Button>
          </div>
        </div>
      </Modal>

      {/* Delete Department In-App Confirmation Modal */}
      <ConfirmDialog
        open={Boolean(deptToDelete)}
        onClose={() => setDeptToDelete(null)}
        onConfirm={confirmDeleteDepartment}
        title="Delete Department"
        description={
          deptToDelete
            ? `Are you sure you want to delete the department "${deptToDelete.name_en}" (${deptToDelete.code})? This action cannot be undone.`
            : ''
        }
        confirmLabel="Delete Department"
        cancelLabel="Cancel"
        destructive={true}
        pending={pending}
      />

      {/* Remove Faculty In-App Confirmation Modal */}
      <ConfirmDialog
        open={Boolean(staffToUnassign)}
        onClose={() => setStaffToUnassign(null)}
        onConfirm={confirmUnassignStaff}
        title="Remove Faculty Member"
        description={
          staffToUnassign
            ? `Are you sure you want to remove ${staffToUnassign.name} from this department? They will become unassigned faculty.`
            : ''
        }
        confirmLabel="Remove Faculty"
        cancelLabel="Cancel"
        destructive={true}
        pending={pending}
      />
    </div>
  );
}
