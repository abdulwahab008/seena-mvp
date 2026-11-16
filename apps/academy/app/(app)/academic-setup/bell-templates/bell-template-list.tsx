'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { setBellTemplateDefault, updateBellPeriodTime } from './actions';
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

function PeriodTime({ period, editable }: { period: BellPeriodRow; editable: boolean }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [start, setStart] = useState(period.start_time.slice(0, 5));
  const [end, setEnd] = useState(period.end_time.slice(0, 5));
  const [pending, startTransition] = useTransition();
  const label = period.period_no ? `Period ${period.period_no}` : period.kind;
  if (!open) {
    return (
      <li>
        {label} — {period.start_time.slice(0, 5)}–{period.end_time.slice(0, 5)}
        {editable && (
          <button type="button" className="ml-2 text-xs underline" onClick={() => setOpen(true)} data-testid={`edit-period-${period.id}`}>
            change
          </button>
        )}
      </li>
    );
  }
  return (
    <li className="flex flex-wrap items-center gap-1">
      {label}
      <input type="time" value={start} onChange={(e) => setStart(e.target.value)} aria-label={`${label} starts`} className="h-8 rounded-md border bg-background px-1 text-foreground" />
      <input type="time" value={end} onChange={(e) => setEnd(e.target.value)} aria-label={`${label} ends`} className="h-8 rounded-md border bg-background px-1 text-foreground" />
      <Button
        type="button"
        size="sm"
        disabled={pending}
        onClick={() =>
          startTransition(async () => {
            const r = await updateBellPeriodTime(period.id, start, end);
            if (r.error) toast.error(r.error);
            else {
              toast.success(`${label} time saved.`);
              setOpen(false);
              router.refresh();
            }
          })
        }
      >
        Save
      </Button>
    </li>
  );
}

export function BellTemplateList({ templates, canEdit }: { templates: BellTemplateRow[]; canEdit: boolean }) {
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
                  <PeriodTime key={`${p.id}-${p.start_time}-${p.end_time}`} period={p} editable={canEdit && !t.is_locked} />
                ))}
            </ul>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
