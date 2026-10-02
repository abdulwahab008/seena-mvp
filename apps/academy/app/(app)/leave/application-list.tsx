'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { cancelLeave } from './actions';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Calendar, Clock, AlertCircle } from 'lucide-react';

export type ApplicationRow = {
  id: string;
  from_date: string;
  to_date: string;
  is_half_day: boolean;
  working_days: number;
  status: string;
  reason: string | null;
  leave_type: { code: string; name_en: string; is_paid?: boolean } | null;
};

function statusBadgeVariant(status: string): 'warning' | 'success' | 'destructive' | 'outline' {
  switch (status) {
    case 'pending':
      return 'warning';
    case 'approved':
      return 'success';
    case 'rejected':
      return 'destructive';
    default:
      return 'outline';
  }
}

function CancelButton({ applicationId }: { applicationId: string }) {
  const [pending, startTransition] = useTransition();
  const onCancel = () => {
    startTransition(async () => {
      const result = await cancelLeave(applicationId);
      if (result.error) toast.error(result.error);
      else toast.success('Application cancelled.');
    });
  };
  return (
    <Button
      type="button"
      variant="outline"
      size="sm"
      onClick={onCancel}
      disabled={pending}
      data-testid={`leave-cancel-${applicationId}`}
      className="text-xs h-8 text-destructive hover:bg-destructive/10 hover:text-destructive"
    >
      {pending ? 'Cancelling…' : 'Cancel'}
    </Button>
  );
}

export function ApplicationList({ applications }: { applications: ApplicationRow[] }) {
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
          <Calendar className="h-4 w-4" />
          My Leave Applications ({applications.length})
        </h2>
      </div>

      {applications.length === 0 ? (
        <Card className="border-dashed">
          <CardContent className="flex flex-col items-center justify-center p-8 text-center text-muted-foreground">
            <Clock className="h-8 w-8 stroke-1 text-muted-foreground/60 mb-2" />
            <p className="text-sm font-medium">No leave applications yet.</p>
            <p className="text-xs text-muted-foreground mt-0.5">
              Submit your first leave application using the form above.
            </p>
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-2">
          {applications.map((a) => (
            <Card
              key={a.id}
              data-testid={`leave-app-row-${a.leave_type?.code}-${a.from_date}`}
              className="hover:border-primary/30 transition-colors"
            >
              <CardContent className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-4">
                <div className="space-y-1">
                  <div className="flex items-center gap-2">
                    <p className="font-semibold text-foreground text-sm">
                      {a.leave_type?.name_en ?? 'Leave'}
                    </p>
                    {a.leave_type?.is_paid !== undefined && (
                      <span className="text-[10px] font-medium px-1.5 py-0.2 rounded bg-muted text-muted-foreground">
                        {a.leave_type.is_paid ? 'Paid' : 'Unpaid'}
                      </span>
                    )}
                  </div>
                  <p className="text-xs text-muted-foreground flex items-center gap-1.5">
                    <span>
                      {a.from_date} to {a.to_date}
                    </span>
                    <span>·</span>
                    <span>
                      {a.working_days} day(s){a.is_half_day ? ' (half day)' : ''}
                    </span>
                  </p>
                  {a.reason && (
                    <p className="text-xs text-muted-foreground italic line-clamp-1">
                      &ldquo;{a.reason}&rdquo;
                    </p>
                  )}
                </div>

                <div className="flex items-center gap-2 self-start sm:self-center">
                  <Badge
                    variant={statusBadgeVariant(a.status)}
                    data-testid={`leave-app-status-${a.leave_type?.code}-${a.from_date}`}
                    className="capitalize text-xs font-semibold"
                  >
                    {a.status}
                  </Badge>
                  {a.status === 'approved' && <CancelButton applicationId={a.id} />}
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
