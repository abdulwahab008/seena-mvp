'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { seedFeeHeads, setFeeHeadActive } from './actions';
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
          <CardContent className="flex items-center justify-between p-4">
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
            <ToggleActiveButton id={h.id} isActive={h.is_active} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
