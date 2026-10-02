'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { markCurrent } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { TermEditor } from './term-editor';

export type SessionRow = {
  id: string;
  name: string;
  starts_on: string;
  ends_on: string;
  status: string;
  is_current: boolean;
  campus_name: string;
  terms: Array<{ name: string; starts_on: string; ends_on: string; weightage: string | number }>;
};

export function SessionList({ sessions }: { sessions: SessionRow[] }) {
  const [pending, startTransition] = useTransition();
  const [openTermsFor, setOpenTermsFor] = useState<string | null>(null);

  if (sessions.length === 0) {
    return <p className="text-sm text-muted-foreground">No sessions yet.</p>;
  }

  return (
    <div className="space-y-2">
      {sessions.map((s) => (
        <Card key={s.id} data-testid={`session-card-${s.name}`}>
          <CardContent className="space-y-2 p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="font-medium">
                  {s.name} <span className="text-muted-foreground">({s.campus_name})</span>
                </p>
                <p className="text-sm text-muted-foreground">
                  {s.starts_on} → {s.ends_on} · {s.status}
                  {s.is_current && ' · current'}
                </p>
              </div>
              <div className="flex gap-2">
                {!s.is_current && (
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={pending}
                    onClick={() =>
                      startTransition(async () => {
                        const result = await markCurrent(s.id);
                        if (result.error) toast.error(result.error);
                        else toast.success(`${s.name} is now the current session.`);
                      })
                    }
                  >
                    Make current
                  </Button>
                )}
                <Button variant="ghost" size="sm" onClick={() => setOpenTermsFor(openTermsFor === s.id ? null : s.id)}>
                  {openTermsFor === s.id ? 'Hide terms' : 'Manage terms'}
                </Button>
              </div>
            </div>
            {openTermsFor === s.id && <TermEditor sessionId={s.id} existingTerms={s.terms} />}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
