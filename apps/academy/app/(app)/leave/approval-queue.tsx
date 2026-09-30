'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { decideLeave } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Check, X, Clock, User, Calendar } from 'lucide-react';

export type PendingRow = {
  id: string;
  from_date: string;
  to_date: string;
  is_half_day: boolean;
  working_days: number;
  reason: string | null;
  leave_type: { name_en: string; is_paid?: boolean } | null;
  staff: { full_name: string; employee_code?: string } | null;
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
    <Button
      type="button"
      variant={variant}
      size="sm"
      disabled={pending}
      onClick={onClick}
      className="text-xs h-8 font-medium gap-1"
    >
      {decision === 'approved' ? <Check className="h-3.5 w-3.5" /> : <X className="h-3.5 w-3.5" />}
      {label}
    </Button>
  );
}

export function ApprovalQueue({ applications }: { applications: PendingRow[] }) {
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
          <Clock className="h-4 w-4 text-warning" />
          Pending Approvals Queue ({applications.length})
        </h2>
      </div>

      {applications.length === 0 ? (
        <Card className="border-dashed">
          <CardContent className="flex flex-col items-center justify-center p-8 text-center text-muted-foreground">
            <Check className="h-8 w-8 text-emerald-500 mb-2 stroke-[2.5]" />
            <p className="text-sm font-semibold text-foreground">All caught up!</p>
            <p className="text-xs text-muted-foreground mt-0.5">
              There are no pending leave applications awaiting administrative decision.
            </p>
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-2">
          {applications.map((a) => (
            <Card
              key={a.id}
              data-testid={`approval-row-${a.staff?.full_name}-${a.from_date}`}
              className="border-warning/40 shadow-xs hover:border-warning transition-colors"
            >
              <CardContent className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 p-4">
                <div className="space-y-1">
                  <div className="flex items-center gap-2">
                    <span className="font-semibold text-foreground text-sm flex items-center gap-1.5">
                      <User className="h-3.5 w-3.5 text-muted-foreground" />
                      {a.staff?.full_name ?? 'Unknown staff'}
                    </span>
                    <span className="text-muted-foreground text-xs">·</span>
                    <span className="text-xs font-medium text-foreground">
                      {a.leave_type?.name_en ?? 'Leave'}
                    </span>
                    {a.leave_type?.is_paid !== undefined && (
                      <Badge variant={a.leave_type.is_paid ? 'success' : 'outline'} className="text-[10px] py-0 px-1.5">
                        {a.leave_type.is_paid ? 'Paid' : 'Unpaid'}
                      </Badge>
                    )}
                  </div>

                  <p className="text-xs text-muted-foreground flex items-center gap-1.5">
                    <Calendar className="h-3.5 w-3.5 text-muted-foreground/80" />
                    <span>
                      {a.from_date} to {a.to_date}
                      {a.is_half_day ? ' (half day)' : ''}
                    </span>
                    <span>·</span>
                    <span className="font-semibold text-foreground">
                      {a.working_days} working day(s)
                    </span>
                  </p>

                  {a.reason && (
                    <p className="text-xs text-muted-foreground bg-muted/30 p-2 rounded-md border mt-1 italic">
                      &ldquo;{a.reason}&rdquo;
                    </p>
                  )}
                </div>

                <div className="flex items-center gap-2 self-start sm:self-center shrink-0">
                  <DecideButton applicationId={a.id} decision="approved" label="Approve" variant="default" />
                  <DecideButton applicationId={a.id} decision="rejected" label="Reject" variant="destructive" />
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
