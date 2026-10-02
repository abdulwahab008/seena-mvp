import Link from 'next/link';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SubmitForm } from './submit-form';
import { SubmissionRealtimeRefresher } from '../submission-realtime-refresher';

export const metadata = { title: 'Submit homework | Parent Portal' };

type SearchParams = { homework?: string; enrolment?: string };

export default async function SubmitHomeworkPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const ids = z.object({ homework: z.string().uuid(), enrolment: z.string().uuid() }).safeParse(sp);
  if (!ids.success) return <p className="text-sm text-muted-foreground">Open this page from a homework assignment.</p>;

  const supabase = await supabaseServer();
  const [{ data: hw }, { data: submission }] = await Promise.all([
    supabase.from('homework').select('id, title, description, due_date, max_score').eq('id', ids.data.homework).maybeSingle(),
    supabase.from('homework_submission').select('id, status, version, pending_version, submission_text, submitted_at, is_late, late_by_minutes, feedback_code, feedback_remark, score').eq('homework_id', ids.data.homework).eq('enrolment_id', ids.data.enrolment).maybeSingle(),
  ]);
  if (!hw) return <p className="text-sm text-muted-foreground">This assignment is not available.</p>;

  const [{ data: files }, { data: history }] = submission
    ? await Promise.all([
        supabase.from('homework_submission_file').select('id, original_filename, version').eq('submission_id', submission.id).order('created_at'),
        supabase.from('homework_submission_version').select('version, snapshot, archived_at').eq('submission_id', submission.id).order('version', { ascending: false }),
      ])
    : [{ data: [] as never[] }, { data: [] as never[] }];
  const live = submission && submission.status !== 'draft';
  const currentFiles = (files ?? []).filter((f) => f.version === submission?.version);

  return (
    <div className="space-y-6">
      <div>
        <Link href="/portal/homework" className="text-sm text-muted-foreground underline">
          Back to homework
        </Link>
        <h2 className="mt-1 text-xl font-semibold">{hw.title}</h2>
        <p className="text-sm text-muted-foreground">Due {hw.due_date} (end of day, Pakistan time)</p>
        {hw.description && <p className="mt-1 text-sm">{hw.description}</p>}
      </div>

      <SubmissionRealtimeRefresher enrolmentId={ids.data.enrolment} />

      {live && (
        <Card data-testid="current-submission">
          <CardHeader>
            <CardTitle className="flex items-center justify-between text-base">
              <span>Your submission (version {submission.version})</span>
              <span className="flex items-center gap-2">
                {submission.is_late && <Badge variant="destructive">Late by {submission.late_by_minutes} min</Badge>}
                <Badge variant={submission.status === 'checked' ? 'success' : 'outline'}>{submission.status}</Badge>
              </span>
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm">
            {submission.submission_text && (
              <p dir="auto" data-testid="submission-text">
                {submission.submission_text}
              </p>
            )}
            {submission.feedback_code && (
              <div className="rounded-md border p-2" data-testid="teacher-feedback">
                <Badge variant="success" className="capitalize">
                  {submission.feedback_code.replace('_', ' ')}
                </Badge>
                {submission.score !== null && hw.max_score !== null && (
                  <span className="ml-2 font-medium">
                    {Number(submission.score)} / {Number(hw.max_score)}
                  </span>
                )}
                {submission.feedback_remark && (
                  <p dir="auto" className="mt-1">
                    {submission.feedback_remark}
                  </p>
                )}
              </div>
            )}
            {currentFiles.map((f) => (
              <p key={f.id}>
                <a href={`/api/homework-submissions/files/${f.id}`} className="underline" target="_blank" rel="noreferrer">
                  {f.original_filename}
                </a>
              </p>
            ))}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{live ? 'Replace your submission' : 'Submit your work'}</CardTitle>
        </CardHeader>
        <CardContent>
          <SubmitForm homeworkId={hw.id} enrolmentId={ids.data.enrolment} locked={submission?.status === 'checked'} />
        </CardContent>
      </Card>

      {(history ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Earlier versions</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm" data-testid="submission-history">
            {(history ?? []).map((h) => (
              <p key={h.version}>
                Version {h.version} — archived {new Date(h.archived_at).toLocaleString()}
              </p>
            ))}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
