'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { decideLeave } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type PendingRow = {
  id: string;
  from_date: string;
  to_date: string;
  is_half_day: boolean;
  working_days: number;
  reason: string | null;
  leave_type: { name_en: string } | null;
  staff: { full_name: string } | null;
};

function DecideButton({
  applicationId,
  decision,
  label,
  variant,
}: {
  applicationId: string;
  decision: 'approved' | 'rejected';
  label: string;
  variant: 'default' | 'destructive';
}) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    const fd = new FormData();
    fd.set('applicationId', applicationId);
    fd.set('decision', decision);
    startTransition(async () => {
      const result = await decideLeave({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success(`Application ${decision}.`);
    });
  };

  return (
    <Button type="button" variant={variant} disabled={pending} onClick={onClick}>
      {label}
    </Button>
  );
}

export function ApprovalQueue({ applications }: { applications: PendingRow[] }) {
  return (
    <div className="space-y-2">
      <h2 className="text-sm font-medium text-muted-foreground">Pending decisions</h2>
      {applications.length === 0 ? (
        <p className="text-sm text-muted-foreground">Nothing awaiting your decision.</p>
      ) : (
        applications.map((a) => (
          <Card key={a.id} data-testid={`approval-row-${a.staff?.full_name}-${a.from_date}`}>
            <CardContent className="flex items-center justify-between gap-4 p-4">
              <div>
                <p className="font-medium">
                  {a.staff?.full_name ?? 'Unknown staff'} — {a.leave_type?.name_en ?? 'Leave'}
                </p>
                <p className="text-sm text-muted-foreground">
                  {a.from_date} to {a.to_date}
                  {a.is_half_day ? ' (half day)' : ''} · {a.working_days} day(s)
                  {a.reason ? ` · ${a.reason}` : ''}
                </p>
              </div>
              <div className="flex gap-2">
                <DecideButton applicationId={a.id} decision="approved" label="Approve" variant="default" />
                <DecideButton applicationId={a.id} decision="rejected" label="Reject" variant="destructive" />
              </div>
            </CardContent>
          </Card>
        ))
      )}
    </div>
  );
}
