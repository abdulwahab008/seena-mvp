'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { syllabusTopicSchema, syllabusUnitSchema, type SyllabusTopicInput, type SyllabusUnitInput } from '@/lib/validation';
import { addTopic, addUnit, cloneSyllabus, deleteTopic, deleteUnit, linkChapter, reorderTopics, reorderUnits, unlinkChapter, updateUnit, type SyllabusScope } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type UnitRow = { id: string; sequence: number; title: string; titleUr: string | null; plannedPeriods: number; targetMonth: string | null; topics: { id: string; sequence: number; title: string; plannedPeriods: number }[]; chapters: { id: string; book: string; chapter: string }[] };

function useRun() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (fn: () => Promise<{ error: string | null }>, ok?: string) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) {
        if (ok) toast.success(ok);
        router.refresh();
      }
    });
  return { pending, error, run };
}

export function UnitForm({ scope, unit, onDone }: { scope?: SyllabusScope; unit?: UnitRow; onDone?: () => void }) {
  const { pending, error, run } = useRun();
  const form = useForm<SyllabusUnitInput>({
    resolver: zodResolver(syllabusUnitSchema),
    defaultValues: unit ? { title: unit.title, titleUr: unit.titleUr ?? '', plannedPeriods: unit.plannedPeriods, targetMonth: unit.targetMonth?.slice(0, 7) ?? '' } : { title: '', titleUr: '', plannedPeriods: 8, targetMonth: '' },
  });
  const onSubmit = form.handleSubmit((v) => {
    if (unit) run(async () => {
      const r = await updateUnit(unit.id, v);
      if (!r.error) onDone?.();
      return r;
    }, 'Chapter saved.');
    else if (scope) run(() => addUnit(scope, v), 'Chapter added.');
  });
  const id = (k: string) => `${k}${unit ? `-${unit.id}` : ''}`;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-5" noValidate>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor={id('unitTitle')}>Chapter title</Label>
        <Input id={id('unitTitle')} {...form.register('title')} />
        {form.formState.errors.title && <p className="text-xs text-destructive">{form.formState.errors.title.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor={id('unitTitleUr')}>Urdu title</Label>
        <Input id={id('unitTitleUr')} dir="rtl" {...form.register('titleUr')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor={id('unitPeriods')}>Planned periods</Label>
        <Input id={id('unitPeriods')} type="number" {...form.register('plannedPeriods', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor={id('unitMonth')}>Target month</Label>
        <Input id={id('unitMonth')} type="month" {...form.register('targetMonth')} />
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-5">{error}</p>}
      <div className="sm:col-span-5">
        <Button type="submit" disabled={pending} data-testid={unit ? 'save-unit' : 'add-unit'}>
          {unit ? 'Save chapter' : 'Add chapter'}
        </Button>
      </div>
    </form>
  );
}

function TopicForm({ unitId }: { unitId: string }) {
  const { pending, error, run } = useRun();
  const form = useForm<SyllabusTopicInput>({ resolver: zodResolver(syllabusTopicSchema), defaultValues: { title: '', plannedPeriods: 2 } });
  const onSubmit = form.handleSubmit((v) => {
    run(() => addTopic(unitId, v));
    form.reset({ title: '', plannedPeriods: v.plannedPeriods });
  });
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-center gap-2" noValidate>
      <Input aria-label="Topic title" className="h-8 w-52" placeholder="New topic" {...form.register('title')} />
      <Input aria-label="Topic periods" type="number" className="h-8 w-20" {...form.register('plannedPeriods', { valueAsNumber: true })} />
      <Button size="sm" variant="outline" type="submit" disabled={pending}>
        Add topic
      </Button>
      {(error || form.formState.errors.title) && <span role="alert" className="text-xs text-destructive">{error ?? form.formState.errors.title?.message}</span>}
    </form>
  );
}

function ChapterLinks({ unit }: { unit: UnitRow }) {
  const { pending, error, run } = useRun();
  const [book, setBook] = useState('');
  const [chapter, setChapter] = useState('');
  return (
    <div className="space-y-1 pl-4" data-testid="unit-chapters">
      {unit.chapters.map((c) => (
        <div key={c.id} className="flex items-center gap-2 text-muted-foreground">
          <span>
            Textbook: {c.book}, {c.chapter}
          </span>
          <Button size="sm" variant="ghost" disabled={pending} onClick={() => run(() => unlinkChapter(c.id))}>
            Unlink
          </Button>
        </div>
      ))}
      <div className="flex flex-wrap items-center gap-2">
        <Input aria-label="Textbook" className="h-8 w-40" placeholder="Textbook" value={book} onChange={(e) => setBook(e.target.value)} />
        <Input aria-label="Textbook chapter" className="h-8 w-40" placeholder="Chapter" value={chapter} onChange={(e) => setChapter(e.target.value)} />
        <Button
          size="sm"
          variant="outline"
          disabled={pending}
          onClick={() =>
            run(async () => {
              const r = await linkChapter(unit.id, book, chapter);
              if (!r.error) setChapter('');
              return r;
            })
          }
        >
          Link textbook chapter
        </Button>
        {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
      </div>
    </div>
  );
}

export function UnitList({ units }: { units: UnitRow[] }) {
  const { pending, error, run } = useRun();
  const [editing, setEditing] = useState<string | null>(null);
  const moveTopic = (u: UnitRow, index: number, by: -1 | 1) => {
    const ids = u.topics.map((t) => t.id);
    const target = index + by;
    if (target < 0 || target >= ids.length) return;
    [ids[index], ids[target]] = [ids[target]!, ids[index]!];
    run(() => reorderTopics(u.id, ids));
  };
  const move = (index: number, by: -1 | 1) => {
    const ids = units.map((u) => u.id);
    const target = index + by;
    if (target < 0 || target >= ids.length) return;
    [ids[index], ids[target]] = [ids[target]!, ids[index]!];
    run(() => reorderUnits(ids));
  };
  return (
    <div className="space-y-3" data-testid="syllabus-units">
      {units.length === 0 && <p className="text-sm text-muted-foreground">No chapters yet for this class, subject and board.</p>}
      {units.map((u, i) => (
        <div key={u.id} className="space-y-2 rounded-md border p-3 text-sm" data-testid="syllabus-unit">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="font-medium">
              {u.sequence}. {u.title}
              {u.titleUr ? <span dir="rtl" className="ml-2 text-muted-foreground">{u.titleUr}</span> : null}
            </span>
            <span className="flex items-center gap-1">
              <span className="text-muted-foreground">
                {u.plannedPeriods} periods{u.targetMonth ? ` · by ${u.targetMonth.slice(0, 7)}` : ''}
              </span>
              <Button size="sm" variant="ghost" aria-label={`Move ${u.title} up`} disabled={pending || i === 0} onClick={() => move(i, -1)}>
                Up
              </Button>
              <Button size="sm" variant="ghost" aria-label={`Move ${u.title} down`} disabled={pending || i === units.length - 1} onClick={() => move(i, 1)}>
                Down
              </Button>
              <Button size="sm" variant="ghost" disabled={pending} onClick={() => setEditing(editing === u.id ? null : u.id)}>
                {editing === u.id ? 'Close' : 'Edit'}
              </Button>
              <Button size="sm" variant="ghost" disabled={pending} onClick={() => run(() => deleteUnit(u.id), 'Chapter deleted.')}>
                Delete
              </Button>
            </span>
          </div>
          {editing === u.id && <UnitForm unit={u} onDone={() => setEditing(null)} />}
          <ul className="space-y-1 pl-4">
            {u.topics.map((t, ti) => (
              <li key={t.id} className="flex items-center justify-between">
                <span>
                  {u.sequence}.{t.sequence} {t.title} <span className="text-muted-foreground">({t.plannedPeriods})</span>
                </span>
                <span className="flex items-center gap-1">
                  <Button size="sm" variant="ghost" aria-label={`Move ${t.title} up`} disabled={pending || ti === 0} onClick={() => moveTopic(u, ti, -1)}>
                    Up
                  </Button>
                  <Button size="sm" variant="ghost" aria-label={`Move ${t.title} down`} disabled={pending || ti === u.topics.length - 1} onClick={() => moveTopic(u, ti, 1)}>
                    Down
                  </Button>
                  <Button size="sm" variant="ghost" disabled={pending} onClick={() => run(() => deleteTopic(t.id))}>
                    Remove
                  </Button>
                </span>
              </li>
            ))}
          </ul>
          <TopicForm unitId={u.id} />
          <ChapterLinks unit={u} />
        </div>
      ))}
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
    </div>
  );
}

export function CloneForm({ campusId, fromSessionId, classLevelId, subjectId, sessions }: { campusId: string; fromSessionId: string; classLevelId: string; subjectId: string; sessions: { id: string; name: string }[] }) {
  const { pending, error, run } = useRun();
  const [to, setTo] = useState(sessions[0]?.id ?? '');
  if (sessions.length === 0) return <p className="text-sm text-muted-foreground">There is no other session to copy into yet.</p>;
  return (
    <div className="space-y-1">
      <div className="flex items-center gap-2">
        <select aria-label="Copy to session" className="h-9 rounded-md border bg-background px-2 text-sm" value={to} onChange={(e) => setTo(e.target.value)}>
          {sessions.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
        <Button size="sm" variant="outline" disabled={pending} data-testid="clone-syllabus" onClick={() => run(() => cloneSyllabus({ campusId, fromSessionId, toSessionId: to, classLevelId, subjectId }), 'Syllabus copied.')}>
          Copy syllabus to that session
        </Button>
      </div>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
