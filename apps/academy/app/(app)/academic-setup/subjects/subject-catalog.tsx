'use client';

import { useState, useMemo, useTransition } from 'react';
import Link from 'next/link';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { SubjectModal, type SubjectItem } from './subject-modal';
import { toggleSubjectActive } from './actions';
import {
  BookOpen,
  Plus,
  Search,
  CheckCircle2,
  XCircle,
  FileCheck,
  Edit2,
  Power,
  ArrowRight,
  Layers,
  GraduationCap,
  Sparkles,
} from 'lucide-react';

export function SubjectCatalog({
  subjects,
  canManage,
}: {
  subjects: SubjectItem[];
  canManage: boolean;
}) {
  const [pending, startTransition] = useTransition();
  const [search, setSearch] = useState('');
  const [typeFilter, setTypeFilter] = useState<string>('ALL');
  const [modalOpen, setModalOpen] = useState(false);
  const [editingSubject, setEditingSubject] = useState<SubjectItem | null>(null);

  // Filtered subject list
  const filtered = useMemo(() => {
    return subjects.filter((s) => {
      const matchesSearch =
        s.code.toLowerCase().includes(search.toLowerCase()) ||
        s.name_en.toLowerCase().includes(search.toLowerCase());
      const matchesType = typeFilter === 'ALL' || s.subject_type === typeFilter;
      return matchesSearch && matchesType;
    });
  }, [subjects, search, typeFilter]);

  // Counts for KPI metrics
  const totalCount = subjects.length;
  const coreCount = subjects.filter((s) => s.subject_type === 'CORE').length;
  const electiveCount = subjects.filter((s) => s.subject_type === 'ELECTIVE').length;
  const examinableCount = subjects.filter((s) => s.is_examinable).length;

  const handleToggleActive = (subject: SubjectItem) => {
    startTransition(async () => {
      const res = await toggleSubjectActive(subject.id, !subject.is_active);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(
          subject.is_active
            ? `Subject "${subject.name_en}" deactivated.`
            : `Subject "${subject.name_en}" activated.`
        );
      }
    });
  };

  return (
    <div className="space-y-6">
      {/* Top Banner & Action */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground flex items-center gap-2.5">
            <BookOpen className="w-6 h-6 text-primary" />
            Master Subject Catalog
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Institutional subjects available across classes, exam terms, timetables, and teacher competency rosters.
          </p>
        </div>

        {canManage && (
          <Button
            onClick={() => {
              setEditingSubject(null);
              setModalOpen(true);
            }}
            className="gap-2 shrink-0"
          >
            <Plus className="w-4 h-4" />
            Add Subject
          </Button>
        )}
      </div>

      {/* Workflow Navigation Hint */}
      <div className="rounded-xl border border-primary/20 bg-primary/5 p-4 flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div className="flex items-start gap-3">
          <div className="p-2 rounded-lg bg-primary/10 text-primary shrink-0 mt-0.5 sm:mt-0">
            <Layers className="w-5 h-5" />
          </div>
          <div>
            <h4 className="text-sm font-semibold text-foreground">
              Looking to assign subjects to a specific class grade?
            </h4>
            <p className="text-xs text-muted-foreground mt-0.5">
              Curriculum Mapping lets you select any class (e.g. Class 9, Class 10), assign weekly periods, and set compulsory or elective options.
            </p>
          </div>
        </div>
        <Link href="/academic-setup/curriculum">
          <Button variant="outline" size="sm" className="gap-1.5 whitespace-nowrap bg-background">
            Go to Curriculum Mapping
            <ArrowRight className="w-3.5 h-3.5" />
          </Button>
        </Link>
      </div>

      {/* KPI Cards */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="p-4 rounded-xl border bg-card shadow-sm">
          <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
            Total Subjects
          </div>
          <div className="text-2xl font-bold text-foreground mt-1">{totalCount}</div>
          <p className="text-xs text-muted-foreground mt-0.5">Active in institutional registry</p>
        </div>

        <div className="p-4 rounded-xl border bg-card shadow-sm">
          <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
            Core Compulsory
          </div>
          <div className="text-2xl font-bold text-blue-600 dark:text-blue-400 mt-1">
            {coreCount}
          </div>
          <p className="text-xs text-muted-foreground mt-0.5">Mandatory foundational subjects</p>
        </div>

        <div className="p-4 rounded-xl border bg-card shadow-sm">
          <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
            Elective Streams
          </div>
          <div className="text-2xl font-bold text-purple-600 dark:text-purple-400 mt-1">
            {electiveCount}
          </div>
          <p className="text-xs text-muted-foreground mt-0.5">Science, Humanities, Arts choices</p>
        </div>

        <div className="p-4 rounded-xl border bg-card shadow-sm">
          <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
            Examinable Subjects
          </div>
          <div className="text-2xl font-bold text-emerald-600 dark:text-emerald-400 mt-1">
            {examinableCount}
          </div>
          <p className="text-xs text-muted-foreground mt-0.5">Graded in term report cards</p>
        </div>
      </div>

      {/* Search & Filter Bar */}
      <div className="flex flex-col sm:flex-row items-center gap-3">
        <div className="relative w-full sm:w-72">
          <Search className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Search code or subject..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9"
          />
        </div>

        <div className="flex items-center gap-1.5 overflow-x-auto w-full sm:w-auto pb-1 sm:pb-0">
          {[
            { id: 'ALL', label: 'All Types' },
            { id: 'CORE', label: 'Core' },
            { id: 'ELECTIVE', label: 'Elective' },
            { id: 'ADDITIONAL', label: 'Additional' },
            { id: 'NON_EXAMINABLE', label: 'Non-Examinable' },
          ].map((tab) => (
            <button
              key={tab.id}
              onClick={() => setTypeFilter(tab.id)}
              className={`px-3 py-1.5 text-xs font-medium rounded-lg transition-colors whitespace-nowrap ${
                typeFilter === tab.id
                  ? 'bg-primary text-primary-foreground'
                  : 'bg-muted/50 hover:bg-muted text-muted-foreground hover:text-foreground'
              }`}
            >
              {tab.label}
            </button>
          ))}
        </div>
      </div>

      {/* Subjects Table */}
      <div className="rounded-xl border bg-card shadow-sm overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/30 text-left text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              <th className="py-3 px-4">Code</th>
              <th className="py-3 px-4">Subject Name</th>
              <th className="py-3 px-4">Classification</th>
              <th className="py-3 px-4">Exam Status</th>
              <th className="py-3 px-4">Status</th>
              {canManage && <th className="py-3 px-4 text-right">Actions</th>}
            </tr>
          </thead>
          <tbody className="divide-y divide-border/60">
            {filtered.map((s) => (
              <tr
                key={s.id}
                data-testid={`subject-row-${s.code}`}
                className="hover:bg-muted/20 transition-colors"
              >
                {/* Code */}
                <td className="py-3.5 px-4 font-mono font-bold text-xs">
                  <span className="px-2 py-1 rounded bg-muted text-foreground border border-border/60">
                    {s.code}
                  </span>
                </td>

                {/* Name */}
                <td className="py-3.5 px-4 font-medium text-foreground">
                  {s.name_en}
                </td>

                {/* Classification Badge */}
                <td className="py-3.5 px-4">
                  {s.subject_type === 'CORE' && (
                    <Badge variant="outline" className="border-blue-500/30 text-blue-700 dark:text-blue-300 bg-blue-500/10">
                      Core Compulsory
                    </Badge>
                  )}
                  {s.subject_type === 'ELECTIVE' && (
                    <Badge variant="outline" className="border-purple-500/30 text-purple-700 dark:text-purple-300 bg-purple-500/10">
                      Elective
                    </Badge>
                  )}
                  {s.subject_type === 'ADDITIONAL' && (
                    <Badge variant="outline" className="border-amber-500/30 text-amber-700 dark:text-amber-300 bg-amber-500/10">
                      Additional
                    </Badge>
                  )}
                  {s.subject_type === 'NON_EXAMINABLE' && (
                    <Badge variant="outline" className="border-slate-500/30 text-slate-700 dark:text-slate-300 bg-slate-500/10">
                      Non-Examinable
                    </Badge>
                  )}
                </td>

                {/* Exam Status & Default Marks */}
                <td className="py-3.5 px-4 text-xs">
                  {s.is_examinable ? (
                    <div className="flex items-center gap-1.5 text-emerald-600 dark:text-emerald-400 font-medium">
                      <CheckCircle2 className="w-4 h-4 shrink-0" />
                      <span>Examinable ({s.default_max_marks ?? 100} Marks)</span>
                    </div>
                  ) : (
                    <div className="flex items-center gap-1.5 text-muted-foreground">
                      <XCircle className="w-4 h-4 shrink-0" />
                      <span>Non-Examinable</span>
                    </div>
                  )}
                </td>

                {/* Status Toggle */}
                <td className="py-3.5 px-4">
                  {s.is_active ? (
                    <Badge variant="outline" className="border-emerald-500/30 text-emerald-700 dark:text-emerald-300 bg-emerald-500/10 text-xs">
                      Active
                    </Badge>
                  ) : (
                    <Badge variant="outline" className="border-rose-500/30 text-rose-700 dark:text-rose-300 bg-rose-500/10 text-xs">
                      Inactive
                    </Badge>
                  )}
                </td>

                {/* Actions */}
                {canManage && (
                  <td className="py-3.5 px-4 text-right">
                    <div className="flex items-center justify-end gap-1.5">
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        disabled={pending}
                        onClick={() => {
                          setEditingSubject(s);
                          setModalOpen(true);
                        }}
                        className="h-8 px-2.5 text-xs gap-1"
                      >
                        <Edit2 className="w-3.5 h-3.5" />
                        Edit
                      </Button>
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        disabled={pending}
                        onClick={() => handleToggleActive(s)}
                        className={`h-8 px-2.5 text-xs gap-1 ${
                          s.is_active
                            ? 'text-destructive hover:text-destructive hover:bg-destructive/10'
                            : 'text-emerald-600 hover:text-emerald-600 hover:bg-emerald-50'
                        }`}
                      >
                        <Power className="w-3.5 h-3.5" />
                        {s.is_active ? 'Deactivate' : 'Activate'}
                      </Button>
                    </div>
                  </td>
                )}
              </tr>
            ))}

            {filtered.length === 0 && (
              <tr>
                <td
                  colSpan={canManage ? 6 : 5}
                  className="py-10 text-center text-muted-foreground text-sm"
                >
                  No subjects found matching your criteria.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {/* In-app Modal */}
      <SubjectModal
        open={modalOpen}
        onClose={() => {
          setModalOpen(false);
          setEditingSubject(null);
        }}
        subject={editingSubject}
      />
    </div>
  );
}
