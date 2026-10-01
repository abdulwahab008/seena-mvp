'use client';

import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  BOARD_CODES,
  boardPatternSchema,
  buildSetsSchema,
  cooldownSettingsSchema,
  paperRequestSchema,
  type BoardPatternInput,
  type BuildSetsInput,
  type CooldownSettingsInput,
  type PaperRequestFormInput,
} from '@/lib/validation';
import { buildSets, requestPaper, retryJob, saveCooldownSettings, savePattern } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type PaperOption = { id: string; label: string };
export type PatternOption = { id: string; label: string; totalMarks: number };

export function RequestForm({ papers, patterns }: { papers: PaperOption[]; patterns: PatternOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<PaperRequestFormInput>({
    resolver: zodResolver(paperRequestSchema),
    defaultValues: { examSubjectId: papers[0]?.id ?? '', boardPatternId: patterns[0]?.id ?? '', chaptersText: '', totalMarks: patterns[0]?.totalMarks ?? 0, setCount: 1 },
  });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await requestPaper(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Paper requested. It is queued; the job card below tracks it.');
        form.setValue('chaptersText', '');
        router.refresh();
      }
    }),
  );
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-6" noValidate>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="reqPaper">Exam paper</Label>
        <select id="reqPaper" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('examSubjectId')}>
          {papers.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="reqPattern">Board pattern</Label>
        <select
          id="reqPattern"
          className="h-10 w-full rounded-md border bg-background px-2 text-sm"
          {...form.register('boardPatternId', {
            onChange: (e) => {
              const p = patterns.find((x) => x.id === e.target.value);
              if (p) form.setValue('totalMarks', p.totalMarks);
            },
          })}
        >
          {patterns.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="reqMarks">Total marks</Label>
        <Input id="reqMarks" type="number" {...form.register('totalMarks', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="reqSets">Sets</Label>
        <Input id="reqSets" type="number" {...form.register('setCount', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1 sm:col-span-6">
        <Label htmlFor="reqChapters">Chapters (comma separated)</Label>
        <Input id="reqChapters" placeholder="Ch.1, Ch.2, Ch.3, Ch.4" {...form.register('chaptersText')} />
      </div>
      <div className="sm:col-span-6">
        <Button type="submit" disabled={pending || papers.length === 0 || patterns.length === 0} data-testid="request-paper">
          Generate paper
        </Button>
      </div>
      {(error || firstError) && (
        <p role="alert" className="text-sm text-destructive sm:col-span-6" data-testid="request-error">
          {error ?? firstError}
        </p>
      )}
    </form>
  );
}

export function PatternForm() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<BoardPatternInput>({
    resolver: zodResolver(boardPatternSchema),
    defaultValues: { code: '', name: '', board: 'FBISE', mcqCount: 12, mcqMarks: 1, shortCount: 9, shortMarks: 3, longCount: 2, longMarks: 13 },
  });
  const total = (() => {
    const v = form.watch();
    return (v.mcqCount || 0) * (v.mcqMarks || 0) + (v.shortCount || 0) * (v.shortMarks || 0) + (v.longCount || 0) * (v.longMarks || 0);
  })();
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await savePattern(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Pattern saved.');
        form.reset({ ...v, code: '', name: '' });
        router.refresh();
      }
    }),
  );
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  const num = (name: 'mcqCount' | 'mcqMarks' | 'shortCount' | 'shortMarks' | 'longCount' | 'longMarks', label: string) => (
    <div className="space-y-1">
      <Label htmlFor={`pat-${name}`}>{label}</Label>
      <Input id={`pat-${name}`} type="number" {...form.register(name, { valueAsNumber: true })} />
    </div>
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-6" noValidate>
      <div className="space-y-1">
        <Label htmlFor="patCode">Pattern code</Label>
        <Input id="patCode" {...form.register('code')} />
      </div>
      <div className="space-y-1 sm:col-span-3">
        <Label htmlFor="patName">Pattern name</Label>
        <Input id="patName" {...form.register('name')} />
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="patBoard">Board</Label>
        <select id="patBoard" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('board')}>
          {BOARD_CODES.map((b) => (
            <option key={b} value={b}>
              {b}
            </option>
          ))}
        </select>
      </div>
      {num('mcqCount', 'MCQs')}
      {num('mcqMarks', 'Marks each')}
      {num('shortCount', 'Short questions')}
      {num('shortMarks', 'Marks each')}
      {num('longCount', 'Long questions')}
      {num('longMarks', 'Marks each')}
      <p className="text-sm text-muted-foreground sm:col-span-6" data-testid="pattern-total">
        Total: {total} marks
      </p>
      <div className="sm:col-span-6">
        <Button type="submit" variant="outline" disabled={pending} data-testid="save-pattern">
          Save pattern
        </Button>
      </div>
      {(error || firstError) && <p role="alert" className="text-sm text-destructive sm:col-span-6">{error ?? firstError}</p>}
    </form>
  );
}

/** FR-I07: build Set A / Set B from the school's own question bank. */
export function BuildSetsForm({ papers, patterns }: { papers: PaperOption[]; patterns: PatternOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<BuildSetsInput>({
    resolver: zodResolver(buildSetsSchema),
    defaultValues: { examSubjectId: papers[0]?.id ?? '', boardPatternId: patterns[0]?.id ?? '', chaptersText: '', setCount: 2, maxIdentical: 2, replace: false },
  });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await buildSets(v);
      setError(r.error);
      if (!r.error) {
        toast.success(`${r.paperIds?.length ?? 0} set papers built as drafts.`);
        router.refresh();
      }
    }),
  );
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-6" noValidate>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="setsPaper">Exam paper</Label>
        <select id="setsPaper" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('examSubjectId')}>
          {papers.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="setsPattern">Board pattern</Label>
        <select id="setsPattern" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('boardPatternId')}>
          {patterns.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="setsCount">Sets</Label>
        <Input id="setsCount" type="number" {...form.register('setCount', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="setsShared">Shared at most</Label>
        <Input id="setsShared" type="number" {...form.register('maxIdentical', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1 sm:col-span-5">
        <Label htmlFor="setsChapters">Chapters (comma separated)</Label>
        <Input id="setsChapters" placeholder="Ch.1, Ch.2" {...form.register('chaptersText')} />
      </div>
      <label className="flex items-end gap-2 pb-2 text-sm">
        <input type="checkbox" {...form.register('replace')} /> Replace existing drafts
      </label>
      <div className="sm:col-span-6">
        <Button type="submit" variant="outline" disabled={pending || papers.length === 0 || patterns.length === 0} data-testid="build-sets">
          Build sets from the bank
        </Button>
      </div>
      {(error || firstError) && (
        <p role="alert" className="text-sm text-destructive sm:col-span-6" data-testid="build-sets-error">
          {error ?? firstError}
        </p>
      )}
    </form>
  );
}

/** FR-I06: how long a class is shielded from seeing a question again, and whether a repeat blocks publication. */
export function CooldownSettingsForm({ campusId, terms, mode }: { campusId: string; terms: number; mode: 'warn' | 'block' }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<CooldownSettingsInput>({ resolver: zodResolver(cooldownSettingsSchema), defaultValues: { campusId, questionCooldownTerms: terms, cooldownMode: mode } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveCooldownSettings(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Reuse cooldown saved.');
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="cdTerms">Cooldown (terms)</Label>
        <Input id="cdTerms" type="number" className="w-28" {...form.register('questionCooldownTerms', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="cdMode">When a flagged paper is published</Label>
        <select id="cdMode" className="h-10 rounded-md border bg-background px-2 text-sm" {...form.register('cooldownMode')}>
          <option value="warn">Warn only</option>
          <option value="block">Block unless overridden with a reason</option>
        </select>
      </div>
      <Button type="submit" variant="outline" disabled={pending} data-testid="save-cooldown">
        Save
      </Button>
      {(error || form.formState.errors.questionCooldownTerms) && <p role="alert" className="text-sm text-destructive">{error ?? form.formState.errors.questionCooldownTerms?.message}</p>}
    </form>
  );
}

export function RetryButton({ jobId }: { jobId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="flex items-center gap-2">
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="retry-job"
        onClick={() =>
          startTransition(async () => {
            const r = await retryJob(jobId);
            setError(r.error);
            if (!r.error) router.refresh();
          })
        }
      >
        Retry
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}

/** Refreshes the job cards while anything is queued or running, instead of blocking the page on a spinner. */
export function JobPoller({ active }: { active: boolean }) {
  const router = useRouter();
  useEffect(() => {
    if (!active) return;
    const t = setInterval(() => router.refresh(), 4000);
    return () => clearInterval(t);
  }, [active, router]);
  return null;
}
