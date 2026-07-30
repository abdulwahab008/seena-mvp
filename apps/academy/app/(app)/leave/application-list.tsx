import { Card, CardContent } from '@/components/ui/card';

export type ApplicationRow = {
  id: string;
  from_date: string;
  to_date: string;
  is_half_day: boolean;
  working_days: number;
  status: string;
  reason: string | null;
  leave_type: { code: string; name_en: string } | null;
};

export function ApplicationList({ applications }: { applications: ApplicationRow[] }) {
  return (
    <div className="space-y-2">
      <h2 className="text-sm font-medium text-muted-foreground">My applications</h2>
      {applications.length === 0 ? (
        <p className="text-sm text-muted-foreground">No leave applications yet.</p>
      ) : (
        applications.map((a) => (
          <Card key={a.id} data-testid={`leave-app-row-${a.leave_type?.code}-${a.from_date}`}>
            <CardContent className="flex items-center justify-between p-4">
              <div>
                <p className="font-medium">{a.leave_type?.name_en ?? 'Leave'}</p>
                <p className="text-sm text-muted-foreground">
                  {a.from_date} to {a.to_date}
                  {a.is_half_day ? ' (half day)' : ''} · {a.working_days} day(s)
                </p>
              </div>
              <span className="text-sm font-medium" data-testid={`leave-app-status-${a.leave_type?.code}-${a.from_date}`}>
                {a.status}
              </span>
            </CardContent>
          </Card>
        ))
      )}
    </div>
  );
}
