'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { setConcessionSchemeActive } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type SchemeRow = {
  id: string;
  code: string;
  name_en: string;
  name_ur: string;
  calc_type: string;
  value: number;
  requires_document: boolean;
  is_active: boolean;
  headNames: string[];
};

function ToggleActiveButton({ id, isActive }: { id: string; isActive: boolean }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await setConcessionSchemeActive(id, !isActive, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success(isActive ? 'Scheme deactivated.' : 'Scheme activated.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick}>
      {isActive ? 'Deactivate' : 'Activate'}
    </Button>
  );
}

export function SchemeList({ schemes }: { schemes: SchemeRow[] }) {
  if (schemes.length === 0) {
    return <p className="text-sm text-muted-foreground">No concession schemes yet.</p>;
  }

  return (
    <div className="space-y-2">
      {schemes.map((s) => (
        <Card key={s.id} data-testid={`scheme-row-${s.code}`}>
          <CardContent className="flex items-center justify-between p-4">
            <div>
              <p className="font-medium">
                {s.name_en} <span className="text-muted-foreground">({s.code})</span>
                {s.requires_document && <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">doc required</span>}
                {!s.is_active && <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">inactive</span>}
              </p>
              <p className="text-sm text-muted-foreground">
                {s.calc_type === 'percentage' ? `${s.value}%` : `PKR ${s.value.toLocaleString()}`} off {s.headNames.join(', ')}
              </p>
            </div>
            <ToggleActiveButton id={s.id} isActive={s.is_active} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
