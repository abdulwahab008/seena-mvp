'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { publishHomework } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { AttachmentPanel, type AttachmentRow } from './attachment-panel';
import { BulkCheck, MaxScoreForm, ReviewForm } from './submission-review';
import { NonSubmitters } from './non-submitters';

export type HomeworkRow = {
  id: string;
  title: string;
  status: 'draft' | 'published' | 'archived';
  assignedDate: string;
  dueDate: string;
  sectionLabel: string;
  subjectLabel: string;
  attachments: AttachmentRow[];
  canEdit: boolean;
  maxScore: number | null;
  submissions: { id: string; studentName: string; status: string; isLate: boolean; lateBy: number; text: string | null; feedbackCode: string | null; feedbackRemark: string | null; score: number | null; files: { id: string; name: string }[] }[];
};

function PublishButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await publishHomework(id, { error: null, loadWarning: null }, new FormData());
      if (result.error) toast.error(result.error);
      else {
        toast.success('Published.');
        // FR-H03: advisory only — the assignment is already published by
        // the time this fires, so it's a heads-up, never a retry prompt.
        if (result.loadWarning) toast.warning(result.loadWarning, { duration: 8000 });
      }
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick} data-testid={`homework-publish-${id}`}>
      {pending ? 'Publishing…' : 'Publish'}
    </Button>
  );
}

export function HomeworkList({ rows }: { rows: HomeworkRow[] }) {
  if (rows.length === 0) {
    return <p className="text-sm text-muted-foreground">No homework assignments yet.</p>;
  }

  return (
    <div className="space-y-2">
      {rows.map((h) => (
        <Card key={h.id} data-testid={`homework-row-${h.title}`}>
          <CardContent className="p-4">
            <div className="flex items-center justify-between">
            <div>
              <p className="font-medium">
                {h.title} <span className="text-muted-foreground">({h.subjectLabel})</span>
              </p>
              <p className="text-sm text-muted-foreground">
                {h.sectionLabel} · due {h.dueDate} ·{' '}
                <span data-testid={`homework-status-${h.title}`}>{h.status}</span>
              </p>
            </div>
            {h.status === 'draft' && <PublishButton id={h.id} />}
            </div>
            <AttachmentPanel homeworkId={h.id} attachments={h.attachments} canEdit={h.canEdit} />
            {h.status === 'published' && h.canEdit && <NonSubmitters homeworkId={h.id} pastDue={h.dueDate < new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' })} />}
            {h.submissions.length > 0 && (
              <div className="mt-3 space-y-1 border-t pt-3 text-sm" data-testid="homework-submissions">
                <p className="font-medium">Submissions ({h.submissions.length})</p>
                {h.canEdit && <MaxScoreForm homeworkId={h.id} current={h.maxScore} />}
                {h.canEdit && h.submissions.length > 1 && <BulkCheck homeworkId={h.id} submissionIds={h.submissions.map((s) => s.id)} />}
                {h.submissions.map((s) => (
                  <div key={s.id} data-testid="homework-submission">
                    <span>{s.studentName}</span> · {s.status}
                    {s.isLate ? ` · late by ${s.lateBy} min` : ''}
                    {s.text ? <span dir="auto"> · {s.text}</span> : null}
                    {s.files.map((f) => (
                      <a key={f.id} href={`/api/homework-submissions/files/${f.id}`} className="ml-2 underline" target="_blank" rel="noreferrer">
                        {f.name}
                      </a>
                    ))}
                    <ReviewForm submissionId={s.id} maxScore={h.maxScore} feedbackCode={s.feedbackCode} remark={s.feedbackRemark} score={s.score} />
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
