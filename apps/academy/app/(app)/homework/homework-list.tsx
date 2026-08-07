'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { publishHomework } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type HomeworkRow = {
  id: string;
  title: string;
  status: 'draft' | 'published' | 'archived';
  assignedDate: string;
  dueDate: string;
  sectionLabel: string;
  subjectLabel: string;
};

function PublishButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await publishHomework(id, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Published.');
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
          <CardContent className="flex items-center justify-between p-4">
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
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
