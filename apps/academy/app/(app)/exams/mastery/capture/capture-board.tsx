'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { readQuestionSheet, saveQuestionMarks, saveQuestions, type QuestionSheet } from './actions';
import { gridToRows, parseMark, type CaptureQuestion } from '@/lib/exams/mastery';
import type { MarkSectionOption } from '@/lib/exams/mark-query';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

type Paper = { examSubjectId: string; sectionId: string; label: string };
type Props = { sections: MarkSectionOption[]; papers: Paper[] };

type DraftQuestion = { maxMarks: string; chapterNo: string; chapterTitle: string };

export function CaptureBoard({ sections, papers }: Props) {
  const [sectionId, setSectionId] = useState('');
  const [paperId, setPaperId] = useState('');
  const [sheet, setSheet] = useState<QuestionSheet | null>(null);
  const [draft, setDraft] = useState<DraftQuestion[]>([{ maxMarks: '', chapterNo: '', chapterTitle: '' }]);
  const [grid, setGrid] = useState<Record<string, Record<number, string>>>({});
  const [busy, setBusy] = useState(false);

  const sectionPapers = papers.filter((p) => p.sectionId === sectionId);

  const open = async () => {
    if (!sectionId || !paperId) return;
    const r = await readQuestionSheet(paperId, sectionId);
    if (r.error || !r.sheet) return void toast.error(r.error ?? 'Could not open the paper.');
    setSheet(r.sheet);
    const g: Record<string, Record<number, string>> = {};
    for (const s of r.sheet.students) {
      g[s.enrolment_id] = Object.fromEntries(Object.entries(s.marks).map(([k, v]) => [Number(k), String(v)]));
    }
    setGrid(g);
  };

  const questions: CaptureQuestion[] = (sheet?.questions ?? []).map((q) => ({
    questionNo: q.question_no,
    maxMarks: Number(q.max_marks),
    chapterNo: q.chapter_no,
    chapterTitle: q.topic_tag,
  }));

  const onSaveScheme = async () => {
    setBusy(true);
    const r = await saveQuestions({
      examSubjectId: paperId,
      questions: draft.map((d, i) => ({
        question_no: i + 1,
        max_marks: Number(d.maxMarks),
        chapter_no: d.chapterNo.trim() === '' ? null : Number(d.chapterNo),
        chapter_title: d.chapterTitle,
      })),
    });
    setBusy(false);
    if (r.error) return void toast.error(r.error);
    toast.success(r.message ?? 'Saved.');
    await open();
  };

  const onSaveMarks = async () => {
    const rows = gridToRows(grid, questions);
    if (rows.length === 0) return void toast.error('Enter at least one mark.');
    setBusy(true);
    const r = await saveQuestionMarks({ examSubjectId: paperId, rows });
    setBusy(false);
    if (r.error) return void toast.error(r.error);
    toast.success(r.message ?? 'Saved.');
  };

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="cap-section">Section</Label>
          <select
            id="cap-section"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={sectionId}
            data-testid="cap-section"
            onChange={(e) => {
              setSectionId(e.target.value);
              setPaperId('');
              setSheet(null);
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
          <Label htmlFor="cap-paper">Paper</Label>
          <select
            id="cap-paper"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={paperId}
            data-testid="cap-paper"
            onChange={(e) => {
              setPaperId(e.target.value);
              setSheet(null);
            }}
          >
            <option value="">Choose a paper…</option>
            {sectionPapers.map((p) => (
              <option key={p.examSubjectId} value={p.examSubjectId}>
                {p.label}
              </option>
            ))}
          </select>
        </div>
        <Button variant="outline" disabled={!paperId} data-testid="cap-open" onClick={() => void open()}>
          Open paper
        </Button>
      </section>

      {sheet && sheet.questions.length === 0 && (
        <section className="space-y-3 rounded-md border p-4" data-testid="scheme-editor">
          <p className="font-medium">Define the questions</p>
          <p className="text-xs text-muted-foreground">One row per question, in paper order. Every question names its chapter.</p>
          <table className="w-full text-sm">
            <thead className="text-left text-muted-foreground">
              <tr>
                <th className="py-1">Q</th>
                <th className="py-1">Marks</th>
                <th className="py-1">Chapter no.</th>
                <th className="py-1">Chapter title</th>
              </tr>
            </thead>
            <tbody>
              {draft.map((d, i) => (
                <tr key={i}>
                  <td className="py-1">{i + 1}</td>
                  <td className="py-1">
                    <input
                      className="h-8 w-20 rounded-md border bg-background px-2"
                      inputMode="decimal"
                      value={d.maxMarks}
                      data-testid={`q-max-${i + 1}`}
                      onChange={(e) => setDraft(draft.map((x, j) => (j === i ? { ...x, maxMarks: e.target.value } : x)))}
                    />
                  </td>
                  <td className="py-1">
                    <input
                      className="h-8 w-20 rounded-md border bg-background px-2"
                      inputMode="numeric"
                      value={d.chapterNo}
                      data-testid={`q-chapter-${i + 1}`}
                      onChange={(e) => setDraft(draft.map((x, j) => (j === i ? { ...x, chapterNo: e.target.value } : x)))}
                    />
                  </td>
                  <td className="py-1">
                    <input
                      className="h-8 w-56 rounded-md border bg-background px-2"
                      value={d.chapterTitle}
                      data-testid={`q-title-${i + 1}`}
                      onChange={(e) => setDraft(draft.map((x, j) => (j === i ? { ...x, chapterTitle: e.target.value } : x)))}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="sm"
              data-testid="add-question"
              onClick={() => setDraft([...draft, { maxMarks: '', chapterNo: draft[draft.length - 1]?.chapterNo ?? '', chapterTitle: draft[draft.length - 1]?.chapterTitle ?? '' }])}
            >
              Add question
            </Button>
            <Button disabled={busy} size="sm" data-testid="save-scheme" onClick={() => void onSaveScheme()}>
              Save questions
            </Button>
          </div>
        </section>
      )}

      {sheet && sheet.questions.length > 0 && (
        <section className="space-y-3" data-testid="marks-grid">
          <p className="text-sm text-muted-foreground">
            {sheet.questions.length} questions · {sheet.questions.reduce((a, q) => a + Number(q.max_marks), 0)} marks. A blank
            cell is &ldquo;not entered&rdquo;, never zero.
          </p>
          <div className="overflow-x-auto">
            <table className="text-sm">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="px-2 py-1">Student</th>
                  {sheet.questions.map((q) => (
                    <th key={q.question_no} className="px-2 py-1" title={q.topic_tag}>
                      Q{q.question_no}
                      <span className="block text-xs font-normal">
                        /{Number(q.max_marks)} · {q.topic_tag}
                      </span>
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {sheet.students.map((s) => (
                  <tr key={s.enrolment_id} className="border-t" data-testid={`grid-${s.gr_number}`}>
                    <td className="px-2 py-1">
                      {s.roll_no !== null ? `${s.roll_no}. ` : ''}
                      {s.student_name}
                    </td>
                    {questions.map((q) => {
                      const value = grid[s.enrolment_id]?.[q.questionNo] ?? '';
                      const err = parseMark(value, q.maxMarks).error;
                      return (
                        <td key={q.questionNo} className="px-1 py-1">
                          <input
                            className={`h-8 w-16 rounded-md border bg-background px-2 ${err ? 'border-destructive' : ''}`}
                            inputMode="decimal"
                            value={value}
                            aria-label={`${s.student_name} question ${q.questionNo}`}
                            data-testid={`cell-${s.gr_number}-${q.questionNo}`}
                            onChange={(e) =>
                              setGrid({ ...grid, [s.enrolment_id]: { ...(grid[s.enrolment_id] ?? {}), [q.questionNo]: e.target.value } })
                            }
                          />
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <Button disabled={busy} data-testid="save-marks" onClick={() => void onSaveMarks()}>
            {busy ? 'Saving…' : 'Save marks'}
          </Button>
        </section>
      )}
    </div>
  );
}
