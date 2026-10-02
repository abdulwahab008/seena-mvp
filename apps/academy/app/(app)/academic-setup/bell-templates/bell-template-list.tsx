'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { setBellTemplateDefault } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type BellPeriodRow = {
  id: string;
  segment_ordinal: number;
  period_no: number | null;
  kind: string;
  start_time: string;
  end_time: string;
};

export type BellTemplateRow = {
  id: string;
  shift: string;
  code: string;
  name: string;
  is_default: boolean;
  is_locked: boolean;
  bell_period: BellPeriodRow[];
};

function SetDefaultButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await setBellTemplateDefault(id, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Default template set.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick} data-testid={`set-default-${id}`}>
      Set as default
    </Button>
  );
}

export function BellTemplateList({ templates }: { templates: BellTemplateRow[] }) {
  if (templates.length === 0) {
    return <p className="text-sm text-muted-foreground">No bell templates yet.</p>;
  }

  return (
    <div className="space-y-3">
      {templates.map((t) => (
        <Card key={t.id} data-testid={`bell-template-row-${t.code}`}>
          <CardContent className="space-y-2 p-4">
            <div className="flex items-center justify-between">
              <p className="font-medium">
                {t.name} <span className="text-muted-foreground">({t.code})</span>
                <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">{t.shift}</span>
                {t.is_default && (
                  <span data-testid={`is-default-${t.id}`} className="ml-2 rounded-full border border-emerald-400 px-2 py-0.5 text-xs text-emerald-700">
                    default
                  </span>
                )}
                {t.is_locked && <span className="ml-2 rounded-full border border-amber-400 px-2 py-0.5 text-xs text-amber-700">locked</span>}
              </p>
              {!t.is_default && <SetDefaultButton id={t.id} />}
            </div>
            <ul className="grid grid-cols-2 gap-x-6 gap-y-1 text-sm text-muted-foreground md:grid-cols-3">
              {[...t.bell_period]
                .sort((a, b) => a.segment_ordinal - b.segment_ordinal)
                .map((p) => (
                  <li key={p.id}>
                    {p.period_no ? `Period ${p.period_no}` : p.kind} — {p.start_time.slice(0, 5)}–{p.end_time.slice(0, 5)}
                  </li>
                ))}
            </ul>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
