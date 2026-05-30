'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { toast } from 'sonner';
import type { GradedResult } from '@seena/shared';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent } from '@/components/ui/card';

type SubmissionStatus = 'pending' | 'processing' | 'graded' | 'failed';

type SubmissionRow = {
  id: string;
  studentName: string | null;
  status: SubmissionStatus;
  totalMarks: number | null;
  obtainedMarks: string | null;
  createdAt: string;
  gradedAt: string | null;
};

type SubmissionDetail = SubmissionRow & {
  result: GradedResult | null;
  failureReason: string | null;
};

const STATUS_STYLES: Record<SubmissionStatus, string> = {
  pending: 'bg-amber-100 text-amber-800',
  processing: 'bg-blue-100 text-blue-800',
  graded: 'bg-green-100 text-green-800',
  failed: 'bg-red-100 text-red-800',
};

function StatusBadge({ status }: { status: SubmissionStatus }) {
  return (
    <span
      className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium capitalize ${STATUS_STYLES[status]}`}
    >
      {status}
    </span>
  );
}

export function SubmissionsPanel({ examId }: { examId: string }) {
  const [submissions, setSubmissions] = useState<SubmissionRow[]>([]);
  const [studentName, setStudentName] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [detail, setDetail] = useState<SubmissionDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const refresh = useCallback(async () => {
    try {
      const res = await fetch(`/api/exams/${examId}/submissions`);
      if (!res.ok) throw new Error(await res.text());
      const data = (await res.json()) as { submissions: SubmissionRow[] };
      setSubmissions(data.submissions);
    } catch (e) {
      toast.error((e as Error).message);
    }
  }, [examId]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const hasActive = submissions.some(
    (s) => s.status === 'pending' || s.status === 'processing',
  );

  useEffect(() => {
    if (!hasActive) return;
    const interval = setInterval(() => {
      void refresh();
    }, 5000);
    return () => clearInterval(interval);
  }, [hasActive, refresh]);

  async function onGrade(e: React.FormEvent) {
    e.preventDefault();
    if (!file) return toast.error('Pick a PDF or image first.');
    setSubmitting(true);
    try {
      const urlRes = await fetch(`/api/exams/${examId}/submissions/upload-url`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ filename: file.name, contentType: file.type }),
      });
      if (!urlRes.ok) throw new Error(await urlRes.text());
      const { signedUrl, key } = (await urlRes.json()) as { signedUrl: string; key: string };

      const putRes = await fetch(signedUrl, {
        method: 'PUT',
        headers: { 'content-type': file.type || 'application/pdf' },
        body: file,
      });
      if (!putRes.ok) throw new Error(`upload failed: ${putRes.status}`);

      const create = await fetch(`/api/exams/${examId}/submissions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          studentName: studentName.trim() || undefined,
          storageKey: key,
        }),
      });
      if (!create.ok) throw new Error(await create.text());
      toast.success('Submitted — grading in the background.');
      setStudentName('');
      setFile(null);
      if (fileInputRef.current) fileInputRef.current.value = '';
      await refresh();
    } catch (err) {
      toast.error((err as Error).message);
    } finally {
      setSubmitting(false);
    }
  }

  async function toggleView(id: string) {
    if (expandedId === id) {
      setExpandedId(null);
      setDetail(null);
      return;
    }
    setExpandedId(id);
    setDetail(null);
    setDetailLoading(true);
    try {
      const res = await fetch(`/api/submissions/${id}`);
      if (!res.ok) throw new Error(await res.text());
      const data = (await res.json()) as { submission: SubmissionDetail };
      setDetail(data.submission);
    } catch (e) {
      toast.error((e as Error).message);
      setExpandedId(null);
    } finally {
      setDetailLoading(false);
    }
  }

  return (
    <Card>
      <CardContent className="space-y-6 p-6">
        <form onSubmit={onGrade} className="flex flex-wrap items-end gap-3">
          <div className="flex-1 min-w-[180px]">
            <Label htmlFor="student-name">Student name</Label>
            <Input
              id="student-name"
              value={studentName}
              onChange={(e) => setStudentName(e.target.value)}
              placeholder="Optional"
              className="mt-1"
            />
          </div>
          <div className="flex-1 min-w-[220px]">
            <Label htmlFor="answer-sheet">Answer sheet</Label>
            <Input
              id="answer-sheet"
              ref={fileInputRef}
              type="file"
              accept="application/pdf,image/*"
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
              className="mt-1"
            />
          </div>
          <Button type="submit" disabled={submitting}>
            {submitting ? 'Uploading…' : 'Grade'}
          </Button>
        </form>

        <div className="flex items-center justify-between">
          <p className="text-sm text-muted-foreground">
            {submissions.length} submission{submissions.length === 1 ? '' : 's'}
          </p>
          <Button variant="outline" size="sm" onClick={() => void refresh()}>
            Refresh
          </Button>
        </div>

        {submissions.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No submissions yet. Upload a scanned answer sheet to grade it.
          </p>
        ) : (
          <div className="divide-y rounded-md border">
            {submissions.map((s) => (
              <div key={s.id}>
                <div className="flex items-center gap-3 p-3">
                  <span className="flex-1 font-medium">
                    {s.studentName || 'Unnamed student'}
                  </span>
                  <StatusBadge status={s.status} />
                  <span className="w-24 text-right text-sm tabular-nums">
                    {s.status === 'graded' && s.totalMarks != null
                      ? `${s.obtainedMarks ?? '0'} / ${s.totalMarks}`
                      : '—'}
                  </span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => void toggleView(s.id)}
                    disabled={s.status !== 'graded' && s.status !== 'failed'}
                  >
                    {expandedId === s.id ? 'Hide' : 'View'}
                  </Button>
                </div>
                {expandedId === s.id ? (
                  <div className="border-t bg-muted/30 p-4">
                    {detailLoading ? (
                      <p className="text-sm text-muted-foreground">Loading…</p>
                    ) : detail?.status === 'failed' ? (
                      <p className="text-sm text-red-700">
                        Grading failed: {detail.failureReason ?? 'unknown error'}
                      </p>
                    ) : detail?.result ? (
                      <GradedDetail result={detail.result} />
                    ) : (
                      <p className="text-sm text-muted-foreground">No result available.</p>
                    )}
                  </div>
                ) : null}
              </div>
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

function GradedDetail({ result }: { result: GradedResult }) {
  return (
    <div className="space-y-4">
      <div className="flex items-baseline gap-3">
        <span className="text-lg font-semibold">
          {result.totalAwarded} / {result.totalMax}
        </span>
        <span className="text-sm text-muted-foreground">
          {Math.round(result.percentage)}%
        </span>
      </div>
      {result.overallFeedback ? (
        <p className="text-sm text-muted-foreground">{result.overallFeedback}</p>
      ) : null}
      <div className="space-y-2">
        {result.questions.map((q) => (
          <div key={q.number} className="rounded-md border bg-background p-3 text-sm">
            <div className="flex items-center gap-2">
              <span className="font-medium">
                Q{q.number} <span className="text-muted-foreground">[{q.section}]</span>
              </span>
              <span className="text-muted-foreground">·</span>
              <span className="tabular-nums">
                {q.awarded}/{q.max}
              </span>
              <span className={q.correct ? 'text-green-700' : 'text-red-700'}>
                {q.correct ? '✓' : '✗'}
              </span>
            </div>
            {q.feedback ? (
              <p className="mt-1 text-muted-foreground">{q.feedback}</p>
            ) : null}
            <details className="mt-2 text-xs text-muted-foreground">
              <summary className="cursor-pointer">Answers</summary>
              <div className="mt-1 space-y-1">
                <div>
                  <span className="font-medium text-foreground">Student:</span>{' '}
                  {q.studentAnswer || '—'}
                </div>
                <div>
                  <span className="font-medium text-foreground">Correct:</span>{' '}
                  {q.correctAnswer || '—'}
                </div>
              </div>
            </details>
          </div>
        ))}
      </div>
    </div>
  );
}
