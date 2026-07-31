'use client';

import { useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { declareCompetency, verifyCompetency, suggestSubstitutes, type SubstituteCandidate } from './actions';
import {
  declareCompetencySchema,
  suggestSubstitutesSchema,
  type DeclareCompetencyInput,
  type SuggestSubstitutesInput,
} from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type StaffOption = { id: string; full_name: string };
type SubjectOption = { id: string; name_en: string };
type ClassLevelOption = { id: string; name_en: string; ordinal: number };
type CompetencyRow = {
  id: string;
  staff_id: string;
  subject_id: string;
  min_class_ordinal: number;
  max_class_ordinal: number;
  source: 'DECLARED' | 'INFERRED' | 'VERIFIED';
};

export function CompetencyRegistry({
  staff,
  subjects,
  classLevels,
  competencies,
}: {
  staff: StaffOption[];
  subjects: SubjectOption[];
  classLevels: ClassLevelOption[];
  competencies: CompetencyRow[];
}) {
  const [pending, startTransition] = useTransition();
  const staffName = (id: string) => staff.find((s) => s.id === id)?.full_name ?? id;
  const subjectName = (id: string) => subjects.find((s) => s.id === id)?.name_en ?? id;
  const classLabel = (ordinal: number) => classLevels.find((c) => c.ordinal === ordinal)?.name_en ?? `ordinal ${ordinal}`;

  const {
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<DeclareCompetencyInput>({ resolver: zodResolver(declareCompetencySchema) });

  const onDeclare = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('staffId', values.staffId);
    fd.set('subjectId', values.subjectId);
    fd.set('minClassOrdinal', String(values.minClassOrdinal));
    fd.set('maxClassOrdinal', String(values.maxClassOrdinal));

    startTransition(async () => {
      const result = await declareCompetency({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Competency saved.');
        reset({ staffId: '', subjectId: '' });
      }
    });
  });

  const onVerify = (staffId: string, subjectId: string) => {
    const fd = new FormData();
    fd.set('staffId', staffId);
    fd.set('subjectId', subjectId);
    startTransition(async () => {
      const result = await verifyCompetency({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Competency verified.');
    });
  };

  const [candidates, setCandidates] = useState<SubstituteCandidate[] | null>(null);
  const {
    handleSubmit: handleFindSubmit,
    control: findControl,
    formState: { errors: findErrors },
  } = useForm<SuggestSubstitutesInput>({ resolver: zodResolver(suggestSubstitutesSchema) });

  const onFindSubstitutes = handleFindSubmit((values) => {
    const fd = new FormData();
    fd.set('subjectId', values.subjectId);
    fd.set('classLevelId', values.classLevelId);
    startTransition(async () => {
      const result = await suggestSubstitutes({ error: null, candidates: null }, fd);
      if (result.error) toast.error(result.error);
      setCandidates(result.candidates);
    });
  });

  return (
    <div className="space-y-6">
      <form onSubmit={onDeclare} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
        <div className="space-y-1">
          <Label htmlFor="staffId">Teacher</Label>
          <Controller
            control={control}
            name="staffId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="competency-staff-trigger">
                  <SelectValue placeholder="Select a teacher" />
                </SelectTrigger>
                <SelectContent>
                  {staff.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.full_name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
          {errors.staffId && <p className="text-xs text-destructive">{errors.staffId.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="subjectId">Subject</Label>
          <Controller
            control={control}
            name="subjectId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="competency-subject-trigger">
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
        <div className="space-y-1">
          <Label htmlFor="minClassOrdinal">From class</Label>
          <Controller
            control={control}
            name="minClassOrdinal"
            render={({ field }) => (
              <Select value={field.value?.toString()} onValueChange={(v) => field.onChange(Number(v))}>
                <SelectTrigger data-testid="competency-min-class-trigger">
                  <SelectValue placeholder="From" />
                </SelectTrigger>
                <SelectContent>
                  {classLevels.map((c) => (
                    <SelectItem key={c.id} value={c.ordinal.toString()}>
                      {c.name_en}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="maxClassOrdinal">To class</Label>
          <Controller
            control={control}
            name="maxClassOrdinal"
            render={({ field }) => (
              <Select value={field.value?.toString()} onValueChange={(v) => field.onChange(Number(v))}>
                <SelectTrigger data-testid="competency-max-class-trigger">
                  <SelectValue placeholder="To" />
                </SelectTrigger>
                <SelectContent>
                  {classLevels.map((c) => (
                    <SelectItem key={c.id} value={c.ordinal.toString()}>
                      {c.name_en}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
          {errors.maxClassOrdinal && <p className="text-xs text-destructive">{errors.maxClassOrdinal.message}</p>}
        </div>
        <Button type="submit" disabled={pending} className="col-span-full w-fit">
          {pending ? 'Saving…' : 'Declare competency'}
        </Button>
      </form>

      <div className="rounded-lg border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="p-2">Teacher</th>
              <th className="p-2">Subject</th>
              <th className="p-2">Range</th>
              <th className="p-2">Source</th>
              <th className="p-2" />
            </tr>
          </thead>
          <tbody>
            {competencies.map((c) => (
              <tr key={c.id} data-testid={`competency-row-${staffName(c.staff_id)}-${subjectName(c.subject_id)}`} className="border-b last:border-0">
                <td className="p-2">{staffName(c.staff_id)}</td>
                <td className="p-2">{subjectName(c.subject_id)}</td>
                <td className="p-2">
                  {classLabel(c.min_class_ordinal)} – {classLabel(c.max_class_ordinal)}
                </td>
                <td className="p-2 text-muted-foreground">{c.source}</td>
                <td className="p-2">
                  {c.source !== 'VERIFIED' && (
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      disabled={pending}
                      onClick={() => onVerify(c.staff_id, c.subject_id)}
                    >
                      Verify
                    </Button>
                  )}
                </td>
              </tr>
            ))}
            {competencies.length === 0 && (
              <tr>
                <td className="p-2 text-muted-foreground" colSpan={5}>
                  No competencies declared yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="space-y-3 rounded-lg border p-4">
        <h2 className="text-sm font-medium">Find a substitute</h2>
        <form onSubmit={onFindSubstitutes} className="grid grid-cols-2 gap-3 md:grid-cols-4" noValidate>
          <div className="space-y-1">
            <Label htmlFor="findSubjectId">Subject</Label>
            <Controller
              control={findControl}
              name="subjectId"
              render={({ field }) => (
                <Select value={field.value} onValueChange={field.onChange}>
                  <SelectTrigger data-testid="find-substitute-subject-trigger">
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
            {findErrors.subjectId && <p className="text-xs text-destructive">{findErrors.subjectId.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="findClassLevelId">Class</Label>
            <Controller
              control={findControl}
              name="classLevelId"
              render={({ field }) => (
                <Select value={field.value} onValueChange={field.onChange}>
                  <SelectTrigger data-testid="find-substitute-class-trigger">
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
              )}
            />
            {findErrors.classLevelId && <p className="text-xs text-destructive">{findErrors.classLevelId.message}</p>}
          </div>
          <Button type="submit" disabled={pending} variant="outline" className="w-fit self-end">
            {pending ? 'Searching…' : 'Find substitutes'}
          </Button>
        </form>

        {candidates && (
          <ul className="space-y-1 text-sm" data-testid="substitute-results">
            {candidates.length === 0 && <li className="text-muted-foreground">No candidates found.</li>}
            {candidates.map((cand) => (
              <li key={cand.staff_id} data-testid={`substitute-candidate-${cand.full_name}`}>
                {cand.full_name} — {cand.source}
                {cand.out_of_range && <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">out of class range</span>}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
