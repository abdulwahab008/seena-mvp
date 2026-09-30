'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { toast } from 'sonner';
import { Plus, Trash2 } from 'lucide-react';
import type { PatternSpec, PatternSection } from '@seena/shared/patterns';
import { FORMAT_LABELS, type Format } from '@seena/shared';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { Card, CardContent } from '@/components/ui/card';
import { ConfirmDialog } from '@/components/ui/modal';

type Mode = 'create' | 'edit';

type Props = {
  initial?: PatternSpec;
  mode: Mode;
  patternId?: string;
};

const FORMATS: Format[] = [
  'paper',
  'quiz',
  'assignment',
  'homework',
  'midterm',
  'final',
  'mocktest',
];

const BOARDS: Array<{ value: string; label: string }> = [
  { value: 'FBISE', label: 'FBISE (Federal)' },
  { value: 'PUNJAB', label: 'Punjab Board' },
  { value: 'PINDI', label: 'BISE Rawalpindi' },
  { value: 'SINDH', label: 'Sindh' },
  { value: 'KP', label: 'Khyber Pakhtunkhwa' },
  { value: 'AJK', label: 'AJK' },
  { value: 'CAMBRIDGE_IGCSE', label: 'Cambridge IGCSE' },
  { value: 'CAMBRIDGE_O_LEVEL', label: 'Cambridge O Level' },
  { value: 'CAMBRIDGE_A_LEVEL', label: 'Cambridge A Level' },
  { value: 'OTHER', label: 'Other' },
];

const QUESTION_TYPES: Array<{ value: PatternSection['type']; label: string }> = [
  { value: 'mcq', label: 'MCQ' },
  { value: 'short', label: 'Short Answer' },
  { value: 'long', label: 'Long Answer' },
  { value: 'fill_blank', label: 'Fill in the Blank' },
  { value: 'true_false', label: 'True / False' },
];

const selectClass =
  'mt-1 flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm';

function emptySection(): PatternSection {
  return {
    type: 'mcq',
    title: 'Section A',
    instructions: 'Choose the correct option.',
    questionCount: 10,
    marksPerQuestion: 1,
  };
}

export function PatternBuilder({ initial, mode, patternId }: Props) {
  const router = useRouter();
  const [name, setName] = useState(initial?.name ?? '');
  const [format, setFormat] = useState<Format>(initial?.format ?? 'paper');
  const [board, setBoard] = useState<string>(initial?.board ?? 'OTHER');
  const [grade, setGrade] = useState<string>(
    initial?.grade != null ? String(initial.grade) : '',
  );
  const [subject, setSubject] = useState(initial?.subject ?? '');
  const [notes, setNotes] = useState(initial?.notes ?? '');
  const [sections, setSections] = useState<PatternSection[]>(
    initial?.sections ?? [emptySection()],
  );
  const [busy, setBusy] = useState<'save' | 'delete' | null>(null);
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);

  const totalMarks = useMemo(
    () =>
      sections.reduce(
        (sum, s) => sum + (Number(s.questionCount) || 0) * (Number(s.marksPerQuestion) || 0),
        0,
      ),
    [sections],
  );

  function updateSection(index: number, patch: Partial<PatternSection>) {
    setSections((prev) => prev.map((s, i) => (i === index ? { ...s, ...patch } : s)));
  }

  function addSection() {
    setSections((prev) => [...prev, emptySection()]);
  }

  function removeSection(index: number) {
    if (sections.length <= 1) return;
    setSections((prev) => prev.filter((_, i) => i !== index));
  }

  async function save() {
    if (!name.trim()) {
      toast.error('Name is required');
      return;
    }
    if (sections.length === 0) {
      toast.error('Add at least one section');
      return;
    }

    setBusy('save');
    try {
      const body = {
        name: name.trim(),
        format,
        board,
        grade: grade ? Number(grade) : null,
        subject: subject.trim() ? subject.trim() : null,
        totalMarks,
        sections,
        notes: notes.trim() ? notes.trim() : undefined,
      };

      const url = mode === 'edit' && patternId ? `/api/patterns/${patternId}` : '/api/patterns';
      const method = mode === 'edit' ? 'PATCH' : 'POST';
      const res = await fetch(url, {
        method,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (!res.ok) throw new Error(await res.text());
      toast.success(mode === 'edit' ? 'Pattern updated.' : 'Pattern created.');
      router.push('/settings/patterns');
      router.refresh();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function confirmRemove() {
    if (mode !== 'edit' || !patternId) return;
    setBusy('delete');
    try {
      const res = await fetch(`/api/patterns/${patternId}`, { method: 'DELETE' });
      if (!res.ok) throw new Error(await res.text());
      toast.success('Pattern deleted.');
      setConfirmDeleteOpen(false);
      router.push('/settings/patterns');
      router.refresh();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">
            {mode === 'edit' ? 'Edit pattern' : 'New pattern'}
          </h1>
          <p className="text-sm text-muted-foreground">
            <Link href="/settings/patterns" className="underline">
              Back to patterns
            </Link>
          </p>
        </div>
      </div>

      <Card>
        <CardContent className="grid gap-4 p-6">
          <div>
            <Label htmlFor="name">Name</Label>
            <Input
              id="name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="My FBISE 9th Physics Pattern"
              className="mt-1"
            />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <Label htmlFor="format">Format</Label>
              <select
                id="format"
                value={format}
                onChange={(e) => setFormat(e.target.value as Format)}
                className={selectClass}
              >
                {FORMATS.map((f) => (
                  <option key={f} value={f}>
                    {FORMAT_LABELS[f]}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <Label htmlFor="board">Board</Label>
              <select
                id="board"
                value={board}
                onChange={(e) => setBoard(e.target.value)}
                className={selectClass}
              >
                {BOARDS.map((b) => (
                  <option key={b.value} value={b.value}>
                    {b.label}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <Label htmlFor="grade">Grade</Label>
              <Input
                id="grade"
                type="number"
                min={1}
                max={14}
                value={grade}
                onChange={(e) => setGrade(e.target.value)}
                placeholder="9"
                className="mt-1"
              />
            </div>
            <div>
              <Label htmlFor="subject">Subject</Label>
              <Input
                id="subject"
                value={subject}
                onChange={(e) => setSubject(e.target.value)}
                placeholder="Physics (leave blank for any)"
                className="mt-1"
              />
            </div>
          </div>

          <div>
            <Label htmlFor="notes">Notes</Label>
            <Textarea
              id="notes"
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              placeholder="Anything the generator should know about this pattern."
              className="mt-1"
              rows={3}
            />
          </div>
        </CardContent>
      </Card>

      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-medium">Sections</h2>
          <Button type="button" variant="outline" size="sm" onClick={addSection}>
            <Plus className="mr-1 h-4 w-4" /> Add section
          </Button>
        </div>

        {sections.map((s, i) => (
          <Card key={i}>
            <CardContent className="grid gap-3 p-4">
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium text-muted-foreground">
                  Section {i + 1}
                </span>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => removeSection(i)}
                  disabled={sections.length <= 1}
                  aria-label="Remove section"
                >
                  <Trash2 className="h-4 w-4" />
                </Button>
              </div>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <Label htmlFor={`type-${i}`}>Type</Label>
                  <select
                    id={`type-${i}`}
                    value={s.type}
                    onChange={(e) =>
                      updateSection(i, { type: e.target.value as PatternSection['type'] })
                    }
                    className={selectClass}
                  >
                    {QUESTION_TYPES.map((q) => (
                      <option key={q.value} value={q.value}>
                        {q.label}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <Label htmlFor={`title-${i}`}>Title</Label>
                  <Input
                    id={`title-${i}`}
                    value={s.title}
                    onChange={(e) => updateSection(i, { title: e.target.value })}
                    className="mt-1"
                  />
                </div>
              </div>
              <div>
                <Label htmlFor={`instructions-${i}`}>Instructions</Label>
                <Textarea
                  id={`instructions-${i}`}
                  value={s.instructions}
                  onChange={(e) => updateSection(i, { instructions: e.target.value })}
                  className="mt-1"
                  rows={2}
                />
              </div>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <Label htmlFor={`count-${i}`}>Question count</Label>
                  <Input
                    id={`count-${i}`}
                    type="number"
                    min={1}
                    value={s.questionCount}
                    onChange={(e) =>
                      updateSection(i, { questionCount: Number(e.target.value) || 0 })
                    }
                    className="mt-1"
                  />
                </div>
                <div>
                  <Label htmlFor={`marks-${i}`}>Marks per question</Label>
                  <Input
                    id={`marks-${i}`}
                    type="number"
                    min={0.5}
                    step={0.5}
                    value={s.marksPerQuestion}
                    onChange={(e) =>
                      updateSection(i, { marksPerQuestion: Number(e.target.value) || 0 })
                    }
                    className="mt-1"
                  />
                </div>
              </div>
              <div className="text-xs text-muted-foreground">
                Section subtotal: {(s.questionCount || 0) * (s.marksPerQuestion || 0)} marks
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      <div className="flex items-center justify-between rounded-md border bg-muted/40 px-4 py-3">
        <div className="text-sm">
          <span className="text-muted-foreground">Total marks:</span>{' '}
          <span className="font-semibold">{totalMarks}</span>
        </div>
        <div className="flex gap-2">
          {mode === 'edit' ? (
            <Button
              type="button"
              variant="destructive"
              onClick={() => setConfirmDeleteOpen(true)}
              disabled={busy !== null}
            >
              {busy === 'delete' ? 'Deleting…' : 'Delete'}
            </Button>
          ) : null}
          <Button type="button" onClick={save} disabled={busy !== null}>
            {busy === 'save' ? 'Saving…' : mode === 'edit' ? 'Save changes' : 'Create pattern'}
          </Button>
        </div>
      </div>

      <ConfirmDialog
        open={confirmDeleteOpen}
        onClose={() => setConfirmDeleteOpen(false)}
        onConfirm={() => void confirmRemove()}
        title="Delete Pattern"
        description="Are you sure you want to delete this pattern? Existing exams already created from it will be unaffected."
        confirmLabel="Delete Pattern"
        destructive
        pending={busy === 'delete'}
      />
    </div>
  );
}
