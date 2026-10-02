'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { queueFollowupReminders, queueAppointmentReminders, processSmsFallbacks, markMessageFailed } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type ReminderRow = {
  id: string;
  childName: string;
  reminderKind: string;
  channel: string;
  locale: string;
  toPhone: string;
  templateId: string | null;
  status: string;
  failureCode: string | null;
  createdAt: string;
};

function QueueControls() {
  const [pending, startTransition] = useTransition();

  const run = (fn: () => Promise<{ error: string | null; queued: number | null }>, label: string) => {
    startTransition(async () => {
      const result = await fn();
      if (result.error) toast.error(result.error);
      else toast.success(`${label}: ${result.queued} new row(s) processed.`);
    });
  };

  return (
    <div className="flex flex-wrap gap-2">
      <Button type="button" size="sm" disabled={pending} onClick={() => run(queueFollowupReminders, 'Follow-up reminders')} data-testid="run-followup-queue">
        Check follow-up reminders
      </Button>
      <Button
        type="button"
        size="sm"
        disabled={pending}
        onClick={() => run(queueAppointmentReminders, 'Appointment reminders')}
        data-testid="run-appointment-queue"
      >
        Check appointment reminders
      </Button>
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => run(processSmsFallbacks, 'SMS fallbacks')} data-testid="run-sms-fallbacks">
        Process SMS fallbacks
      </Button>
    </div>
  );
}

function MarkFailedControl({ messageId }: { messageId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await markMessageFailed(messageId, 'META_PERMANENT_FAILURE');
      if (result.error) toast.error(result.error);
      else toast.success('Marked failed.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick} data-testid={`mark-failed-${messageId}`}>
      Simulate delivery failure
    </Button>
  );
}

export function ReminderList({ reminders }: { reminders: ReminderRow[] }) {
  return (
    <div className="space-y-4">
      <QueueControls />
      {reminders.length === 0 ? (
        <p className="text-sm text-muted-foreground">No reminders queued yet.</p>
      ) : (
        <div className="space-y-2">
          {reminders.map((r) => (
            <Card key={r.id} data-testid={`reminder-row-${r.id}`}>
              <CardContent className="flex items-center justify-between p-4 text-sm">
                <div>
                  <p className="font-medium">
                    {r.childName} · {r.reminderKind.replace(/_/g, ' ')}
                  </p>
                  <p className="text-muted-foreground">
                    {r.channel} · {r.locale} · {r.toPhone} · {r.templateId ?? 'no template'}
                  </p>
                  {r.failureCode && <p className="text-xs text-destructive">Failure: {r.failureCode}</p>}
                </div>
                <div className="flex items-center gap-2">
                  <span data-testid={`reminder-status-${r.id}`} className="text-xs font-medium">
                    {r.status}
                  </span>
                  {r.channel === 'whatsapp' && r.status === 'queued' && <MarkFailedControl messageId={r.id} />}
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
