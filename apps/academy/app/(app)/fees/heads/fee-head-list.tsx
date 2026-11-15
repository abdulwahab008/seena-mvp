'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { seedFeeHeads, setFeeHeadActive, setFeeHeadRules } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type FeeHeadRow = {
  id: string;
  code: string;
  name_en: string;
  name_ur: string;
  is_refundable: boolean;
  default_frequency: string;
  is_active: boolean;
  withdrawal_treatment: string | null;
  priority: number | null;
};

function SeedButton({ tenantId }: { tenantId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await seedFeeHeads(tenantId, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Default fee heads seeded.');
    });
  };

  return (
    <Button type="button" disabled={pending} onClick={onClick}>
      {pending ? 'Seeding…' : 'Seed default fee heads'}
    </Button>
  );
}

function ToggleActiveButton({ id, isActive }: { id: string; isActive: boolean }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await setFeeHeadActive(id, !isActive, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success(isActive ? 'Fee head deactivated.' : 'Fee head activated.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick}>
      {isActive ? 'Deactivate' : 'Activate'}
    </Button>
  );
}

function HeadRules({ head }: { head: FeeHeadRow }) {
  const [pending, startTransition] = useTransition();
  const save = (priority: number | null, treatment: 'none' | 'prorate' | null) =>
    startTransition(async () => {
      const r = await setFeeHeadRules(head.id, priority, treatment);
      if (r.error) toast.error(r.error);
      else toast.success('Fee head saved.');
    });
  return (
    <div className="flex flex-wrap items-center gap-2 text-sm">
      <label className="flex items-center gap-1 text-muted-foreground">
        Payment order
        <input
          type="number"
          min={1}
          max={999}
          defaultValue={head.priority ?? ''}
          placeholder="999"
          disabled={pending}
          aria-label={`Payment order for ${head.code}`}
          className="h-8 w-16 rounded-md border bg-background px-2 text-foreground"
          onBlur={(e) => {
            const v = e.target.value;
            if (v !== '' && Number(v) !== head.priority) save(Number(v), null);
          }}
        />
      </label>
      <label className="flex items-center gap-1 text-muted-foreground">
        On leaving
        <select
          defaultValue={head.withdrawal_treatment ?? ''}
          disabled={pending}
          aria-label={`On leaving for ${head.code}`}
          className="h-8 rounded-md border bg-background px-2 text-foreground"
          onChange={(e) => e.target.value && save(null, e.target.value as 'none' | 'prorate')}
        >
          <option value="" disabled>
            {head.default_frequency === 'monthly' ? 'Prorate (default)' : 'Charge in full (default)'}
          </option>
          <option value="prorate">Prorate to days attended</option>
          <option value="none">Charge in full</option>
        </select>
      </label>
    </div>
  );
}

export function FeeHeadList({ tenantId, feeHeads }: { tenantId: string; feeHeads: FeeHeadRow[] }) {
  if (feeHeads.length === 0) {
    return (
      <div className="space-y-2">
        <p className="text-sm text-muted-foreground">No fee heads yet.</p>
        <SeedButton tenantId={tenantId} />
      </div>
    );
  }

  return (
    <div className="space-y-2">
      {feeHeads.map((h) => (
        <Card key={h.id} data-testid={`fee-head-row-${h.code}`}>
          <CardContent className="flex flex-wrap items-center justify-between gap-3 p-4">
            <div>
              <p className="font-medium">
                {h.name_en} <span className="text-muted-foreground">({h.code})</span>
                {h.is_refundable && <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">refundable</span>}
                {!h.is_active && <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">inactive</span>}
              </p>
              <p className="text-sm text-muted-foreground">
                {h.name_ur} · {h.default_frequency.replace(/_/g, ' ')}
              </p>
            </div>
            <div className="flex flex-wrap items-center justify-end gap-3">
              <HeadRules head={h} />
              <ToggleActiveButton id={h.id} isActive={h.is_active} />
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
