'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { cancelInterview, fetchInterviewNotificationPayload, type NotificationPayload } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type InterviewRow = {
  id: string;
  applicationNo: string | null;
  childName: string;
  panelName: string;
  startsAt: string;
  endsAt: string;
  venue: string | null;
  status: string;
};

function NotificationViewer({ interviewId }: { interviewId: string }) {
  const [pending, startTransition] = useTransition();
  const [payload, setPayload] = useState<NotificationPayload | null>(null);

  const onView = () => {
    startTransition(async () => {
      const result = await fetchInterviewNotificationPayload(interviewId);
      if (result.error) toast.error(result.error);
      else setPayload(result.payload);
    });
  };

  return (
    <div className="mt-1">
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onView}>
        Preview notification
      </Button>
      {payload && (
        <p className="mt-1 text-xs text-muted-foreground" data-testid={`notification-preview-${interviewId}`}>
          Channel: {payload.channel} · {payload.phone}
        </p>
      )}
    </div>
  );
}

function CancelButton({ interviewId }: { interviewId: string }) {
  const [pending, startTransition] = useTransition();

  const onCancel = () => {
    startTransition(async () => {
      const result = await cancelInterview(interviewId);
      if (result.error) toast.error(result.error);
      else toast.success('Interview cancelled.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onCancel}>
      Cancel
    </Button>
  );
}

export function InterviewList({ interviews }: { interviews: InterviewRow[] }) {
  if (interviews.length === 0) {
    return <p className="text-sm text-muted-foreground">No interviews booked yet.</p>;
  }

  return (
    <div className="space-y-2">
      {interviews.map((i) => (
        <Card key={i.id} data-testid={`interview-row-${i.id}`}>
          <CardContent className="p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="font-medium">
                  {i.childName} ({i.applicationNo}) with {i.panelName}
                </p>
                <p className="text-sm text-muted-foreground">
                  {new Date(i.startsAt).toLocaleString()} – {new Date(i.endsAt).toLocaleTimeString()} · {i.venue ?? 'No venue set'} ·{' '}
                  <span data-testid={`interview-status-${i.id}`}>{i.status}</span>
                </p>
                <NotificationViewer interviewId={i.id} />
              </div>
              {i.status === 'scheduled' && <CancelButton interviewId={i.id} />}
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
