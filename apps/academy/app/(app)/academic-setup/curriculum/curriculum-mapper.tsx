'use client';

import { useMemo, useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  upsertClassSubject,
  deleteClassSubject,
  copyClassSubjectMap,
  copyCurriculumToMultipleClasses,
  assignSubjectToMultipleClasses,
} from './actions';
import { upsertClassSubjectSchema, type UpsertClassSubjectInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Modal } from '@/components/ui/modal';
import {
  BookOpen,
  Copy,
  Plus,
  Trash2,
  CheckCircle2,
  Clock,
  Layers,
  ChevronDown,
  ChevronRight,
  Sparkles,
  Check,
  AlertCircle,
  GraduationCap,
} from 'lucide-react';

const WEEKLY_SLOT_LIMIT = 40;

type ClassLevel = { id: string; code: string; name_en: string; ordinal: number };
type Subject = { id: string; code: string; name_en: string };
type Mapping = {
  id: string;
  class_level_id: string;
  subject_id: string;
  weekly_periods: number;
  is_compulsory: boolean;
  elective_bucket: number | null;
};
type WeeklyLoad = { class_level_id: string | null; total_weekly_periods: number | null };

export function CurriculumMapper({
  campusId,
  sessionId,
  classLevels,
  subjects,
  mappings,
  weeklyLoad,
}: {
  campusId: string;
  sessionId: string;
  classLevels: ClassLevel[];
  subjects: Subject[];
  mappings: Mapping[];
  weeklyLoad: WeeklyLoad[];
}) {
  const [pending, startTransition] = useTransition();
  const [classLevelId, setClassLevelId] = useState(classLevels[0]?.id ?? '');
  const [showMultiClassCopy, setShowMultiClassCopy] = useState(false);
  const [selectedTargetClassIds, setSelectedTargetClassIds] = useState<string[]>([]);
  const [showMultiAssign, setShowMultiAssign] = useState(false);
  const [extraClassIds, setExtraClassIds] = useState<string[]>([]);

  const currentClass = useMemo(() => {
    return classLevels.find((c) => c.id === classLevelId) ?? classLevels[0];
  }, [classLevels, classLevelId]);

  const rows = useMemo(
    () => mappings.filter((m) => m.class_level_id === classLevelId),
    [mappings, classLevelId]
  );
  const total = weeklyLoad.find((w) => w.class_level_id === classLevelId)?.total_weekly_periods ?? 0;
  const compulsoryCount = rows.filter((r) => r.is_compulsory).length;
  const electiveCount = rows.filter((r) => !r.is_compulsory).length;

  const subjectName = (id: string) => subjects.find((s) => s.id === id)?.name_en ?? id;
  const subjectCode = (id: string) => subjects.find((s) => s.id === id)?.code ?? '';

  const {
    register,
    handleSubmit,
    control,
    reset,
    watch,
    formState: { errors },
  } = useForm<UpsertClassSubjectInput>({
    resolver: zodResolver(upsertClassSubjectSchema),
    defaultValues: { subjectId: '', isCompulsory: true, weeklyPeriods: 6 },
  });
  const isCompulsory = watch('isCompulsory');

  // Submit mapping: maps to current class AND any extra selected classes
  const onSubmit = handleSubmit((values) => {
    const allTargetClasses = Array.from(new Set([classLevelId, ...extraClassIds]));

    startTransition(async () => {
      if (allTargetClasses.length > 1) {
        const result = await assignSubjectToMultipleClasses({
          campusId,
          sessionId,
          classLevelIds: allTargetClasses,
          subjectId: values.subjectId,
          weeklyPeriods: values.weeklyPeriods,
          isCompulsory: values.isCompulsory,
          electiveBucket: values.electiveBucket,
        });
        if (result.error) toast.error(result.error);
        else {
          toast.success(
            `Assigned ${subjectName(values.subjectId)} to ${result.count} classes.`
          );
          reset({ subjectId: '', isCompulsory: true, weeklyPeriods: 6 });
          setExtraClassIds([]);
          setShowMultiAssign(false);
        }
      } else {
        const fd = new FormData();
        fd.set('campusId', campusId);
        fd.set('sessionId', sessionId);
        fd.set('classLevelId', classLevelId);
        fd.set('subjectId', values.subjectId);
        fd.set('weeklyPeriods', String(values.weeklyPeriods));
        if (values.isCompulsory) fd.set('isCompulsory', 'on');
        if (values.electiveBucket !== undefined) fd.set('electiveBucket', String(values.electiveBucket));
        if (values.chooseN !== undefined) fd.set('chooseN', String(values.chooseN));

        const result = await upsertClassSubject({ error: null }, fd);
        if (result.error) toast.error(result.error);
        else {
          toast.success(`${subjectName(values.subjectId)} mapped.`);
          reset({ subjectId: '', isCompulsory: true, weeklyPeriods: 6 });
          setExtraClassIds([]);
          setShowMultiAssign(false);
        }
      }
    });
  });

  // Delete subject from class
  const handleDelete = (mappingId: string, name: string) => {
    startTransition(async () => {
      const res = await deleteClassSubject(mappingId);
      if (res.error) toast.error(res.error);
      else toast.success(`Removed ${name} from ${currentClass?.name_en}.`);
    });
  };

  // Bulk copy curriculum from current class to multiple selected classes
  const handleBulkCopy = () => {
    if (selectedTargetClassIds.length === 0) {
      toast.error('Select at least one class to receive the curriculum.');
      return;
    }

    startTransition(async () => {
      const res = await copyCurriculumToMultipleClasses(
        classLevelId,
        selectedTargetClassIds,
        sessionId,
        campusId
      );
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(
          `Curriculum copied to ${selectedTargetClassIds.length} classes (${res.created} subjects added, ${res.skipped} already mapped).`
        );
        setShowMultiClassCopy(false);
        setSelectedTargetClassIds([]);
      }
    });
  };

  // Quick select helper for classes
  const selectClassesByRange = (minOrd: number, maxOrd: number) => {
    const ids = classLevels
      .filter((c) => c.id !== classLevelId && c.ordinal >= minOrd && c.ordinal <= maxOrd)
      .map((c) => c.id);
    setSelectedTargetClassIds(ids);
  };

  const toggleExtraClass = (id: string) => {
    if (extraClassIds.includes(id)) {
      setExtraClassIds(extraClassIds.filter((cid) => cid !== id));
    } else {
      setExtraClassIds([...extraClassIds, id]);
    }
  };

  return (
    <div className="space-y-6">
      {/* 1. Header Toolbar & Class Navigator */}
      <div className="bg-card border border-border/70 rounded-2xl p-5 shadow-xs space-y-4">
        <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-xl bg-primary/10 text-primary flex items-center justify-center shrink-0">
              <GraduationCap className="w-5 h-5" />
            </div>
            <div>
              <div className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                Active Grade & Section Setup
              </div>
              <div className="flex items-center gap-2.5 mt-0.5">
                <Select value={classLevelId} onValueChange={setClassLevelId}>
                  <SelectTrigger
                    data-testid="curriculum-class-trigger"
                    className="w-56 font-semibold text-base border-none p-0 h-auto focus:ring-0 shadow-none hover:text-primary transition-colors cursor-pointer"
                  >
                    <SelectValue placeholder="Select a class" />
                  </SelectTrigger>
                  <SelectContent>
                    {classLevels.map((c) => (
                      <SelectItem key={c.id} value={c.id}>
                        {c.name_en}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Badge variant="outline" className="text-xs font-semibold px-2 py-0.5 bg-muted border-border/80">
                  {rows.length} {rows.length === 1 ? 'Subject' : 'Subjects'}
                </Badge>
              </div>
            </div>
          </div>

          {/* Action buttons */}
          <div className="flex items-center gap-2.5">
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={pending || rows.length === 0}
              onClick={() => {
                setSelectedTargetClassIds([]);
                setShowMultiClassCopy(true);
              }}
              className="gap-2 h-9 px-3.5 border-border/80 hover:bg-muted font-medium text-xs rounded-xl"
            >
              <Copy className="w-3.5 h-3.5 text-primary" />
              Copy Curriculum Across Classes...
            </Button>
          </div>
        </div>

        {/* Sleek Class Pills Strip */}
        <div className="pt-3 border-t border-border/50">
          <div className="flex items-center gap-1.5 overflow-x-auto pb-1 scrollbar-thin">
            {classLevels.map((c) => {
              const count = mappings.filter((m) => m.class_level_id === c.id).length;
              const isSelected = c.id === classLevelId;
              return (
                <button
                  key={c.id}
                  type="button"
                  onClick={() => setClassLevelId(c.id)}
                  className={`px-3.5 py-1.5 rounded-lg text-xs font-medium transition-all whitespace-nowrap flex items-center gap-2 ${
                    isSelected
                      ? 'bg-primary text-primary-foreground font-semibold shadow-xs scale-[1.02]'
                      : 'bg-muted/40 hover:bg-muted text-muted-foreground hover:text-foreground'
                  }`}
                >
                  <span>{c.name_en}</span>
                  <span
                    className={`text-[10px] px-1.5 py-0.5 rounded-full font-mono ${
                      isSelected
                        ? 'bg-primary-foreground/20 text-primary-foreground'
                        : 'bg-background/80 text-muted-foreground border border-border/40'
                    }`}
                  >
                    {count}
                  </span>
                </button>
              );
            })}
          </div>
        </div>
      </div>

      {/* 2. Mapped Subjects Table for Current Class */}
      <div className="bg-card border border-border/70 rounded-2xl shadow-xs overflow-hidden">
        {/* Table Header Bar with Load Meter */}
        <div className="p-5 border-b border-border/70 bg-muted/15 flex flex-col sm:flex-row sm:items-center justify-between gap-3">
          <div className="space-y-1">
            <div className="flex items-center gap-2">
              <h3 className="text-lg font-bold text-foreground">
                {currentClass?.name_en} Curriculum
              </h3>
              <span className="text-xs text-muted-foreground">
                ({compulsoryCount} Compulsory · {electiveCount} Elective)
              </span>
            </div>
            <p className="text-xs text-muted-foreground">
              Official subject offerings and period allocations for {currentClass?.name_en}.
            </p>
          </div>

          {/* Weekly Period Gauge */}
          <div
            data-testid="curriculum-total"
            className={`text-xs font-semibold px-3.5 py-1.5 rounded-xl border flex items-center gap-2 ${
              total > WEEKLY_SLOT_LIMIT
                ? 'bg-destructive/10 text-destructive border-destructive/30'
                : 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-300 border-emerald-500/25'
            }`}
          >
            <Clock className="w-3.5 h-3.5" />
            <span>Total weekly periods: {total} / {WEEKLY_SLOT_LIMIT}</span>
          </div>
        </div>

        {/* Subjects Table */}
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border/60 bg-muted/30 text-left text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              <th className="py-3.5 px-5">Subject</th>
              <th className="py-3.5 px-5">Weekly Periods</th>
              <th className="py-3.5 px-5">Classification</th>
              <th className="py-3.5 px-5 text-right">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border/50">
            {rows.map((r) => {
              const sName = subjectName(r.subject_id);
              const sCode = subjectCode(r.subject_id);
              return (
                <tr
                  key={r.id}
                  data-testid={`curriculum-row-${sName}`}
                  className="hover:bg-muted/20 transition-colors"
                >
                  {/* Subject Name & Code */}
                  <td className="py-4 px-5">
                    <div className="flex items-center gap-2.5">
                      <span className="font-mono text-xs px-2 py-0.5 rounded-md bg-muted text-foreground font-bold border border-border/70">
                        {sCode}
                      </span>
                      <span className="font-semibold text-foreground text-sm">{sName}</span>
                    </div>
                  </td>

                  {/* Weekly Periods */}
                  <td className="py-4 px-5">
                    <div className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-muted/50 border border-border/50 text-xs font-medium">
                      <Clock className="w-3 h-3 text-muted-foreground" />
                      <span className="font-bold text-foreground">{r.weekly_periods}</span>
                      <span className="text-muted-foreground">periods/week</span>
                    </div>
                  </td>

                  {/* Classification */}
                  <td className="py-4 px-5 text-xs">
                    {r.is_compulsory ? (
                      <Badge variant="outline" className="border-blue-500/30 text-blue-700 dark:text-blue-300 bg-blue-500/10 font-medium">
                        Compulsory Core
                      </Badge>
                    ) : (
                      <Badge variant="outline" className="border-purple-500/30 text-purple-700 dark:text-purple-300 bg-purple-500/10 font-medium">
                        Elective (Bucket {r.elective_bucket})
                      </Badge>
                    )}
                  </td>

                  {/* Delete Button */}
                  <td className="py-4 px-5 text-right">
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      disabled={pending}
                      onClick={() => handleDelete(r.id, sName)}
                      className="h-8 w-8 p-0 text-muted-foreground hover:text-destructive hover:bg-destructive/10 rounded-lg transition-colors"
                      title="Remove from class"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  </td>
                </tr>
              );
            })}

            {rows.length === 0 && (
              <tr>
                <td colSpan={4} className="py-14 text-center text-muted-foreground">
                  <div className="w-12 h-12 rounded-2xl bg-muted/60 text-muted-foreground/60 flex items-center justify-center mx-auto mb-3">
                    <BookOpen className="w-6 h-6" />
                  </div>
                  <div className="font-semibold text-foreground text-sm">No subjects mapped to {currentClass?.name_en}</div>
                  <p className="text-xs text-muted-foreground mt-1 max-w-sm mx-auto">
                    Use the form below to assign subjects one-by-one or copy the curriculum from another class.
                  </p>
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {/* 3. Sleek "Add Subject to Class" Panel */}
      <div className="bg-card border border-border/70 rounded-2xl p-6 shadow-xs space-y-5">
        <div className="flex items-center justify-between">
          <div className="space-y-0.5">
            <h3 className="text-base font-bold text-foreground flex items-center gap-2">
              <Plus className="w-4 h-4 text-primary" />
              Add Subject to {currentClass?.name_en}
            </h3>
            <p className="text-xs text-muted-foreground">
              Select a subject from the catalog and set its weekly period allocation.
            </p>
          </div>
        </div>

        <form onSubmit={onSubmit} className="space-y-4" noValidate>
          <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-4 items-end">
            {/* Subject Dropdown */}
            <div className="space-y-1.5 sm:col-span-2">
              <Label htmlFor="subjectId" className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                Subject <span className="text-destructive">*</span>
              </Label>
              <Controller
                control={control}
                name="subjectId"
                render={({ field }) => (
                  <Select value={field.value} onValueChange={field.onChange}>
                    <SelectTrigger data-testid="curriculum-subject-trigger" className="h-10 rounded-xl">
                      <SelectValue placeholder="Select a subject" />
                    </SelectTrigger>
                    <SelectContent>
                      {subjects.map((s) => (
                        <SelectItem key={s.id} value={s.id}>
                          {s.name_en}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              />
              {errors.subjectId && <p className="text-xs text-destructive">{errors.subjectId.message}</p>}
            </div>

            {/* Weekly Periods */}
            <div className="space-y-1.5">
              <Label htmlFor="weeklyPeriods" className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                Weekly periods <span className="text-destructive">*</span>
              </Label>
              <Input
                id="weeklyPeriods"
                type="number"
                min={1}
                max={12}
                {...register('weeklyPeriods')}
                className="h-10 rounded-xl font-medium"
                placeholder="6"
              />
              {errors.weeklyPeriods && <p className="text-xs text-destructive">{errors.weeklyPeriods.message}</p>}
            </div>

            {/* Submit Button */}
            <div>
              <Button type="submit" disabled={pending} className="w-full h-10 rounded-xl font-semibold gap-2 shadow-xs">
                {pending ? (
                  'Saving…'
                ) : (
                  <>
                    <Plus className="w-4 h-4" />
                    Map subject
                  </>
                )}
              </Button>
            </div>
          </div>

          {/* Compulsory vs Elective Row */}
          <div className="flex flex-wrap items-center gap-4 pt-1">
            <label className="flex items-center gap-2 text-xs font-semibold cursor-pointer select-none p-2 rounded-lg hover:bg-muted/40 transition-colors">
              <input
                type="checkbox"
                {...register('isCompulsory')}
                className="w-4 h-4 text-primary rounded border-input focus:ring-primary"
              />
              <span>Compulsory Subject for all students</span>
            </label>

            {!isCompulsory && (
              <div className="flex items-center gap-3">
                <div className="flex items-center gap-1.5">
                  <Label htmlFor="electiveBucket" className="text-xs text-muted-foreground whitespace-nowrap">
                    Bucket:
                  </Label>
                  <Input
                    id="electiveBucket"
                    type="number"
                    min={1}
                    {...register('electiveBucket')}
                    placeholder="1"
                    className="w-16 h-8 text-xs rounded-lg"
                  />
                </div>
                <div className="flex items-center gap-1.5">
                  <Label htmlFor="chooseN" className="text-xs text-muted-foreground whitespace-nowrap">
                    Choose N:
                  </Label>
                  <Input
                    id="chooseN"
                    type="number"
                    min={1}
                    {...register('chooseN')}
                    placeholder="1"
                    className="w-16 h-8 text-xs rounded-lg"
                  />
                </div>
              </div>
            )}
          </div>

          {/* Optional Multi-Class Apply Accordion */}
          <div className="pt-3 border-t border-border/50">
            <button
              type="button"
              onClick={() => setShowMultiAssign(!showMultiAssign)}
              className="flex items-center gap-1.5 text-xs font-semibold text-primary hover:underline cursor-pointer"
            >
              {showMultiAssign ? <ChevronDown className="w-3.5 h-3.5" /> : <ChevronRight className="w-3.5 h-3.5" />}
              <span>Also assign this subject to other classes (e.g. Classes 1 to 5)?</span>
              {extraClassIds.length > 0 && (
                <span className="ml-1 px-2 py-0.5 rounded-full bg-primary/10 text-primary text-[11px] font-bold">
                  {extraClassIds.length} extra selected
                </span>
              )}
            </button>

            {showMultiAssign && (
              <div className="mt-3 p-3.5 rounded-xl border border-border/70 bg-muted/20 space-y-2.5">
                <div className="flex items-center justify-between text-xs">
                  <span className="text-muted-foreground font-medium">
                    Click classes to toggle assignment:
                  </span>
                  {extraClassIds.length > 0 && (
                    <button
                      type="button"
                      onClick={() => setExtraClassIds([])}
                      className="text-destructive hover:underline text-[11px] font-semibold"
                    >
                      Clear Selection
                    </button>
                  )}
                </div>

                <div className="flex flex-wrap gap-2">
                  {classLevels
                    .filter((c) => c.id !== classLevelId)
                    .map((c) => {
                      const selected = extraClassIds.includes(c.id);
                      return (
                        <button
                          key={c.id}
                          type="button"
                          onClick={() => toggleExtraClass(c.id)}
                          className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-all flex items-center gap-1.5 border ${
                            selected
                              ? 'bg-primary text-primary-foreground border-primary font-semibold shadow-2xs'
                              : 'bg-card hover:bg-muted text-muted-foreground border-border/80'
                          }`}
                        >
                          <span>{c.name_en}</span>
                          {selected && <Check className="w-3 h-3 text-primary-foreground" />}
                        </button>
                      );
                    })}
                </div>
              </div>
            )}
          </div>
        </form>
      </div>

      {/* 4. Copy Curriculum Across Classes In-App Modal */}
      <Modal
        open={showMultiClassCopy}
        onClose={() => {
          setShowMultiClassCopy(false);
          setSelectedTargetClassIds([]);
        }}
        title={`Copy Curriculum from ${currentClass?.name_en}`}
        description={`Duplicate all ${rows.length} subjects from ${currentClass?.name_en} to other classes (e.g. across primary grades 1 to 5).`}
        size="lg"
      >
        <div className="space-y-5 pt-2">
          {/* Subjects Preview */}
          <div className="p-4 rounded-xl border border-border/70 bg-muted/20 space-y-2">
            <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
              Subjects to be Copied ({rows.length})
            </div>
            <div className="flex flex-wrap gap-2">
              {rows.map((r) => (
                <span
                  key={r.id}
                  className="px-2.5 py-1 rounded-lg bg-card border border-border/70 text-xs font-semibold text-foreground shadow-2xs"
                >
                  {subjectName(r.subject_id)} ({r.weekly_periods} periods)
                </span>
              ))}
            </div>
          </div>

          {/* Target Classes Selection */}
          <div className="space-y-2.5">
            <div className="flex items-center justify-between">
              <Label className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                Select Destination Classes
              </Label>
              <div className="flex items-center gap-1.5 text-xs">
                <button
                  type="button"
                  onClick={() => selectClassesByRange(2, 6)}
                  className="px-2.5 py-1 rounded-lg bg-muted hover:bg-muted/80 text-foreground font-semibold text-[11px] transition-colors"
                >
                  Classes 1–5
                </button>
                <button
                  type="button"
                  onClick={() => selectClassesByRange(7, 9)}
                  className="px-2.5 py-1 rounded-lg bg-muted hover:bg-muted/80 text-foreground font-semibold text-[11px] transition-colors"
                >
                  Classes 6–8
                </button>
                <button
                  type="button"
                  onClick={() =>
                    setSelectedTargetClassIds(classLevels.filter((c) => c.id !== classLevelId).map((c) => c.id))
                  }
                  className="px-2.5 py-1 rounded-lg bg-muted hover:bg-muted/80 text-foreground font-semibold text-[11px] transition-colors"
                >
                  All
                </button>
                <button
                  type="button"
                  onClick={() => setSelectedTargetClassIds([])}
                  className="px-2.5 py-1 rounded-lg text-destructive hover:underline font-semibold text-[11px]"
                >
                  Clear
                </button>
              </div>
            </div>

            <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2.5 max-h-56 overflow-y-auto p-3 rounded-xl border border-border/70 bg-muted/10">
              {classLevels
                .filter((c) => c.id !== classLevelId)
                .map((c) => {
                  const checked = selectedTargetClassIds.includes(c.id);
                  return (
                    <button
                      key={c.id}
                      type="button"
                      onClick={() => {
                        if (checked) setSelectedTargetClassIds(selectedTargetClassIds.filter((id) => id !== c.id));
                        else setSelectedTargetClassIds([...selectedTargetClassIds, c.id]);
                      }}
                      className={`p-3 rounded-xl border text-left text-xs transition-all flex items-center justify-between ${
                        checked
                          ? 'border-primary bg-primary/10 text-foreground ring-1 ring-primary font-bold shadow-2xs'
                          : 'border-border/70 hover:bg-muted/40 text-muted-foreground bg-card'
                      }`}
                    >
                      <span>{c.name_en}</span>
                      {checked && <Check className="w-3.5 h-3.5 text-primary shrink-0" />}
                    </button>
                  );
                })}
            </div>
          </div>

          {/* Footer */}
          <div className="flex items-center justify-between pt-4 border-t border-border/70">
            <span className="text-xs text-muted-foreground font-medium">
              {selectedTargetClassIds.length}{' '}
              {selectedTargetClassIds.length === 1 ? 'class selected' : 'classes selected'}
            </span>
            <div className="flex items-center gap-2.5">
              <Button
                type="button"
                variant="outline"
                onClick={() => setShowMultiClassCopy(false)}
                disabled={pending}
                className="rounded-xl"
              >
                Cancel
              </Button>
              <Button
                type="button"
                disabled={pending || selectedTargetClassIds.length === 0}
                onClick={handleBulkCopy}
                className="gap-2 rounded-xl font-semibold shadow-xs"
              >
                {pending ? (
                  'Copying…'
                ) : (
                  <>
                    <Copy className="w-4 h-4" />
                    Copy to {selectedTargetClassIds.length} Classes
                  </>
                )}
              </Button>
            </div>
          </div>
        </div>
      </Modal>
    </div>
  );
}
