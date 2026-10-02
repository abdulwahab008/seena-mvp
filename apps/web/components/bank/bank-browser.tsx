'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import { toast } from 'sonner';
import type { Question } from '@seena/shared';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Card, CardContent } from '@/components/ui/card';
import { ConfirmDialog } from '@/components/ui/modal';

export type BankItem = {
  id: string;
  subject: string | null;
  board: string | null;
  grade: number | null;
  chapter: string | null;
  type: string;
  sourceExamId: string | null;
  payload: Question;
};

const SELECT = 'h-9 rounded-md border border-input bg-background px-2 text-sm';

export function BankBrowser({ initial }: { initial: BankItem[] }) {
  const [items, setItems] = useState(initial);
  const [subject, setSubject] = useState('');
  const [type, setType] = useState('');
  const [q, setQ] = useState('');
  const [questionToDelete, setQuestionToDelete] = useState<BankItem | null>(null);

  const subjects = useMemo(
    () => [...new Set(items.map((i) => i.subject).filter((s): s is string => !!s))],
    [items],
  );
  const types = useMemo(() => [...new Set(items.map((i) => i.type))], [items]);

  const filtered = items.filter((i) => {
    if (subject && i.subject !== subject) return false;
    if (type && i.type !== type) return false;
    if (q && !i.payload.prompt.toLowerCase().includes(q.toLowerCase())) return false;
    return true;
  });

  async function confirmDeleteQuestion() {
    if (!questionToDelete) return;
    const id = questionToDelete.id;
    const prev = items;
    setItems((xs) => xs.filter((x) => x.id !== id));
    setQuestionToDelete(null);
    try {
      const res = await fetch(`/api/bank/${id}`, { method: 'DELETE' });
      if (!res.ok) throw new Error(await res.text());
      toast.success('Question removed from bank.');
    } catch (e) {
      setItems(prev);
      toast.error((e as Error).message);
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <select value={subject} onChange={(e) => setSubject(e.target.value)} className={SELECT}>
          <option value="">All subjects</option>
          {subjects.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
        <select value={type} onChange={(e) => setType(e.target.value)} className={SELECT}>
          <option value="">All types</option>
          {types.map((t) => (
            <option key={t} value={t}>
              {t}
            </option>
          ))}
        </select>
        <Input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Search prompt…"
          className="max-w-xs"
        />
        <span className="text-sm text-muted-foreground">
          {filtered.length} of {items.length}
        </span>
      </div>

      {filtered.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            No saved questions. Open an exam and click “Save to bank” on a question.
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-2">
          {filtered.map((i) => {
            const p = i.payload;
            const cog = (p as { cognitiveLevel?: string }).cognitiveLevel;
            const dif = (p as { difficulty?: string }).difficulty;
            return (
              <Card key={i.id}>
                <CardContent className="flex items-start gap-3 p-4">
                  <div className="flex-1 space-y-1">
                    <p className="text-sm">{p.prompt}</p>
                    <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                      <span className="rounded bg-muted px-1.5 py-0.5">{i.type}</span>
                      <span>
                        {p.marks} mark{p.marks === 1 ? '' : 's'}
                      </span>
                      {i.subject ? <span>{i.subject}</span> : null}
                      {i.board ? <span>{i.board}</span> : null}
                      {i.grade != null ? <span>grade {i.grade}</span> : null}
                      {cog ? <span className="rounded bg-muted px-1.5 py-0.5">{cog}</span> : null}
                      {dif ? <span className="rounded bg-muted px-1.5 py-0.5">{dif}</span> : null}
                      {i.sourceExamId ? (
                        <Link href={`/exams/${i.sourceExamId}`} className="underline">
                          source exam
                        </Link>
                      ) : null}
                    </div>
                  </div>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setQuestionToDelete(i)}
                    className="text-red-700 hover:bg-red-50 hover:text-red-800"
                  >
                    Delete
                  </Button>
                </CardContent>
              </Card>
            );
          })}
        </div>
      )}

      <ConfirmDialog
        open={Boolean(questionToDelete)}
        onClose={() => setQuestionToDelete(null)}
        onConfirm={() => void confirmDeleteQuestion()}
        title="Delete Banked Question"
        description="Are you sure you want to delete this question from the question bank? This action cannot be undone."
        confirmLabel="Delete Question"
        destructive
      />
    </div>
  );
}
