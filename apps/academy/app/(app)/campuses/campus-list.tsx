'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { archiveCampus } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type CampusRow = {
  id: string;
  code: string;
  name: string;
  city: string | null;
  status: string;
};

export function CampusList({ campuses }: { campuses: CampusRow[] }) {
  const [pending, startTransition] = useTransition();

  if (campuses.length === 0) {
    return <p className="text-sm text-muted-foreground">No campuses yet.</p>;
  }

  return (
    <div className="space-y-2">
      {campuses.map((c) => (
        <Card key={c.id} data-testid={`campus-card-${c.code}`}>
          <CardContent className="flex items-center justify-between p-4">
            <div>
              <p className="font-medium">
                {c.name} <span className="text-muted-foreground">({c.code})</span>
              </p>
              <p className="text-sm text-muted-foreground">
                {c.city ?? '—'} · {c.status}
              </p>
            </div>
            {c.status === 'active' && (
              <Button
                variant="outline"
                size="sm"
                disabled={pending}
                onClick={() =>
                  startTransition(async () => {
                    const result = await archiveCampus(c.id);
                    if (result.error) toast.error(result.error);
                    else toast.success(`${c.name} archived.`);
                  })
                }
              >
                Archive
              </Button>
            )}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
