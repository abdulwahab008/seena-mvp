'use client';

import { useMemo, useState, useTransition } from 'react';
import { toast } from 'sonner';
import { checkExamEntryReadiness, deleteExamSubject, upsertExamSubject } from './actions';
import type {
  ClassSubjectOption,
  ExamEntryReadiness,
  ExamSubjectRow,
  SectionOption,
} from '@/lib/exams/subject-query';
import {
  MARK_COMPONENT_CODES,
  PASS_EXCEEDS_MAX,
  examSubjectTotalMax,
  type MarkComponentCode,
} from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

type ComponentDraft = { component: MarkComponentCode; maxMarks: string; passMarks: string };

type Props = {
  examTermId: string;
  examTermLabel: string;
  canWrite: boolean;
  configured: ExamSubjectRow[];
  options: ClassSubjectOption[];
  sections: SectionOption[];
};

const BLANK: ComponentDraft[] = [{ component: 'theory', maxMarks: '', passMarks: '' }];

const describe = (o: ClassSubjectOption) =>
  `${o.className}${o.streamName ? ` ${o.streamName}` : ''} — ${o.subjectName}`;

export function SubjectSetup({ examTermId, examTermLabel, canWrite, configured, options, sections }: Props) {
  const [pending, startTransition] = useTransition();
  const [classSubjectId, setClassSubjectId] = useState('');
  const [drafts, setDrafts] = useState<ComponentDraft[]>(BLANK);

  const [previewSection, setPreviewSection] = useState('');
  const [previewSubject, setPreviewSubject] = useState('');
  const [readiness, setReadiness] = useState<ExamEntryReadiness | null>(null);

  // AC1: the total the Controller sees before saving. examSubjectTotalMax is
  // the same sum fn_exam_subject_total_max() computes in SQL.
  const totalMax = useMemo(
    () => examSubjectTotalMax(drafts.map((d) => ({ maxMarks: Number(d.maxMarks) }))),
    [drafts],
  );
  // AC2's rule, shown before the round trip. The database raises the same
  // sentence, and it is the database that actually refuses the save.
  const passExceedsMax = drafts.some(
    (d) => d.maxMarks !== '' && d.passMarks !== '' && Number(d.passMarks) > Number(d.maxMarks),
  );

  const subjectsForSection = useMemo(() => {
    const section = sections.find((s) => s.id === previewSection);
    if (!section) return [];
    const seen = new Set<string>();
    return options
      .filter((o) => o.classLevelId === section.classLevelId)
      .filter((o) => (seen.has(o.subjectId) ? false : (seen.add(o.subjectId), true)));
  }, [options, sections, previewSection]);

  const setDraft = (i: number, patch: Partial<ComponentDraft>) =>
    setDrafts((prev) => prev.map((d, n) => (n === i ? { ...d, ...patch } : d)));

  const onSave = () => {
    if (!classSubjectId) {
      toast.error('Choose a class subject.');
      return;
    }
    const fd = new FormData();
    fd.set('examTermId', examTermId);
    fd.set('classSubjectId', classSubjectId);
    fd.set(
      'components',
      JSON.stringify(
        drafts
          .filter((d) => d.maxMarks !== '')
          .map((d) => ({ component: d.component, maxMarks: Number(d.maxMarks), passMarks: Number(d.passMarks || 0) })),
      ),
    );

    startTransition(async () => {
      const result = await upsertExamSubject({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Exam setup saved.');
        setDrafts(BLANK);
        setClassSubjectId('');
      }
    });
  };

  const onDelete = (id: string) => {
    const fd = new FormData();
    fd.set('examSubjectId', id);
    startTransition(async () => {
      const result = await deleteExamSubject(fd);
      if (result.error) toast.error(result.error);
      else toast.success('Exam setup removed.');
    });
  };

  const onPreview = () => {
    if (!previewSection || !previewSubject) {
      toast.error('Choose a section and a subject.');
      return;
    }
    startTransition(async () => {
      const result = await checkExamEntryReadiness(examTermId, previewSection, previewSubject);
      if (result.error || !result.readiness) {
        toast.error(result.error ?? 'Could not check the exam setup.');
        setReadiness(null);
      } else {
        setReadiness(result.readiness);
      }
    });
  };

  return (
    <div className="space-y-8">
      <section className="space-y-3">
        <h2 className="text-lg font-medium">Configured for {examTermLabel}</h2>
        <div className="rounded-lg border">
          <table className="w-full text-sm">
            <thead className="border-b bg-muted/40 text-left">
              <tr>
                <th className="p-3 font-medium">Class</th>
                <th className="p-3 font-medium">Stream</th>
                <th className="p-3 font-medium">Subject</th>
                <th className="p-3 font-medium">Components</th>
                <th className="p-3 font-medium">Total max</th>
                <th className="p-3 font-medium" />
              </tr>
            </thead>
            <tbody>
              {configured.length === 0 && (
                <tr>
                  <td colSpan={6} className="p-4 text-muted-foreground" data-testid="exam-subject-empty">
                    Nothing configured for this term yet.
                  </td>
                </tr>
              )}
              {configured.map((row) => (
                <tr key={row.id} className="border-b last:border-0" data-testid={`exam-subject-row-${row.subjectName}`}>
                  <td className="p-3">{row.className}</td>
                  <td className="p-3">{row.streamName ?? '—'}</td>
                  <td className="p-3">{row.subjectName}</td>
                  <td className="p-3">
                    {row.components.map((c) => `${c.component} ${c.maxMarks}/${c.passMarks}`).join(', ')}
                  </td>
                  <td
                    className="p-3 font-semibold tabular-nums"
                    data-testid={`exam-subject-total-${row.subjectName}`}
                  >
                    {row.totalMaxMarks}
                  </td>
                  <td className="p-3 text-right">
                    {canWrite && (
                      <Button variant="ghost" size="sm" disabled={pending} onClick={() => onDelete(row.id)}>
                        Remove
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {canWrite && (
        <section className="space-y-3 rounded-lg border p-4">
          <h2 className="text-lg font-medium">Configure a class subject</h2>
          <p className="text-xs text-muted-foreground">
            Configuration is per class, not per section — every section of the class inherits it with no further setup.
          </p>
          <div className="space-y-1">
            <Label htmlFor="classSubjectId">Class subject</Label>
            <select
              id="classSubjectId"
              className="h-9 w-full rounded-md border bg-background px-3 text-sm md:w-96"
              value={classSubjectId}
              data-testid="class-subject-select"
              onChange={(e) => setClassSubjectId(e.target.value)}
            >
              <option value="">Choose a class subject…</option>
              {options.map((o) => (
                <option key={o.id} value={o.id}>
                  {describe(o)}
                  {o.isConfigured ? ' (configured)' : ''}
                </option>
              ))}
            </select>
          </div>

          <div className="space-y-2">
            {drafts.map((d, i) => (
              <div key={i} className="grid grid-cols-2 gap-3 md:grid-cols-4" data-testid={`component-row-${i}`}>
                <div className="space-y-1">
                  <Label htmlFor={`component-${i}`}>Component</Label>
                  <select
                    id={`component-${i}`}
                    className="h-9 w-full rounded-md border bg-background px-3 text-sm"
                    value={d.component}
                    onChange={(e) => setDraft(i, { component: e.target.value as MarkComponentCode })}
                  >
                    {MARK_COMPONENT_CODES.map((c) => (
                      <option key={c} value={c}>
                        {c}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="space-y-1">
                  <Label htmlFor={`maxMarks-${i}`}>Max marks</Label>
                  <Input
                    id={`maxMarks-${i}`}
                    type="number"
                    min={1}
                    value={d.maxMarks}
                    onChange={(e) => setDraft(i, { maxMarks: e.target.value })}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor={`passMarks-${i}`}>Pass marks</Label>
                  <Input
                    id={`passMarks-${i}`}
                    type="number"
                    min={0}
                    value={d.passMarks}
                    onChange={(e) => setDraft(i, { passMarks: e.target.value })}
                  />
                </div>
                {drafts.length > 1 && (
                  <Button
                    variant="ghost"
                    size="sm"
                    className="self-end"
                    onClick={() => setDrafts((prev) => prev.filter((_, n) => n !== i))}
                  >
                    Remove component
                  </Button>
                )}
              </div>
            ))}
          </div>

          <div className="flex flex-wrap items-center gap-4">
            <Button
              variant="outline"
              size="sm"
              disabled={drafts.length >= MARK_COMPONENT_CODES.length}
              data-testid="add-component"
              onClick={() => setDrafts((prev) => [...prev, { component: 'practical', maxMarks: '', passMarks: '' }])}
            >
              Add component
            </Button>
            <p className="text-sm">
              Total max{' '}
              <span className="text-lg font-semibold tabular-nums" data-testid="draft-total-max">
                {totalMax}
              </span>
            </p>
            {passExceedsMax && (
              <p className="text-sm text-destructive" data-testid="draft-pass-error">
                {PASS_EXCEEDS_MAX}
              </p>
            )}
            <Button className="ml-auto" disabled={pending} data-testid="save-exam-subject" onClick={onSave}>
              {pending ? 'Saving…' : 'Save exam setup'}
            </Button>
          </div>
        </section>
      )}

      <section className="space-y-3 rounded-lg border p-4">
        <h2 className="text-lg font-medium">Mark entry readiness</h2>
        <p className="text-xs text-muted-foreground">
          A read-only preview of what a teacher opening mark entry would see. Teacher mark entry itself is FR-I12 and is
          not built yet, so nothing here saves a mark — the columns and the disabled state come from the same
          <code className="mx-1">fn_exam_entry_readiness()</code>
          that grid will call.
        </p>
        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <Label htmlFor="previewSection">Section</Label>
            <select
              id="previewSection"
              className="h-9 rounded-md border bg-background px-3 text-sm"
              value={previewSection}
              data-testid="preview-section-select"
              onChange={(e) => {
                setPreviewSection(e.target.value);
                setPreviewSubject('');
                setReadiness(null);
              }}
            >
              <option value="">Choose a section…</option>
              {sections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="previewSubject">Subject</Label>
            <select
              id="previewSubject"
              className="h-9 rounded-md border bg-background px-3 text-sm"
              value={previewSubject}
              data-testid="preview-subject-select"
              onChange={(e) => {
                setPreviewSubject(e.target.value);
                setReadiness(null);
              }}
            >
              <option value="">Choose a subject…</option>
              {subjectsForSection.map((o) => (
                <option key={o.subjectId} value={o.subjectId}>
                  {o.subjectName}
                </option>
              ))}
            </select>
          </div>
          <Button variant="outline" disabled={pending} data-testid="open-mark-entry" onClick={onPreview}>
            Open mark entry
          </Button>
        </div>

        {readiness && !readiness.ready && (
          <div className="rounded-md border border-dashed p-4" data-testid="mark-entry-disabled">
            <table className="w-full text-sm opacity-50">
              <thead className="border-b text-left">
                <tr>
                  <th className="p-2 font-medium">Student</th>
                  <th className="p-2 font-medium">Marks</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td className="p-2 text-muted-foreground">—</td>
                  <td className="p-2">
                    <Input disabled placeholder="—" />
                  </td>
                </tr>
              </tbody>
            </table>
            <p className="mt-3 text-sm text-destructive" data-testid="mark-entry-pending-message">
              {readiness.message}
            </p>
          </div>
        )}

        {readiness && readiness.ready && (
          <div className="rounded-md border p-4" data-testid="mark-entry-grid">
            <p className="mb-2 text-sm">
              Total max{' '}
              <span className="font-semibold tabular-nums" data-testid="mark-entry-total-max">
                {readiness.total_max_marks}
              </span>
            </p>
            <table className="w-full text-sm">
              <thead className="border-b text-left">
                <tr>
                  <th className="p-2 font-medium">Student</th>
                  {readiness.components.map((c) => (
                    <th key={c.component} className="p-2 font-medium" data-testid={`mark-entry-column-${c.component}`}>
                      {c.component} (max {c.max_marks} / pass {c.pass_marks})
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td className="p-2 text-muted-foreground">Sample row — FR-I12 fills this in</td>
                  {readiness.components.map((c) => (
                    <td key={c.component} className="p-2">
                      <Input disabled placeholder={`0–${c.max_marks}`} />
                    </td>
                  ))}
                </tr>
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
