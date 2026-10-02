'use client';

import * as React from 'react';
import { toast } from 'sonner';
import { setFeature, setPlan, type FlagActionState } from './actions';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type PlanOption = { code: string; name: string };
export type FlagRow = {
  code: string;
  label: string;
  description: string;
  isBeta: boolean;
  /** The resolved answer: override, else plan, else platform default. */
  enabled: boolean;
  /** null when nothing is overridden and the plan decides. */
  override: boolean | null;
};

export function FeatureFlagsView({
  tenantId,
  rows,
  plans,
  planCode,
  canEdit,
}: {
  tenantId: string;
  rows: FlagRow[];
  plans: PlanOption[];
  planCode: string;
  canEdit: boolean;
}) {
  const [pending, startTransition] = React.useTransition();

  const run = (action: (prev: FlagActionState, fd: FormData) => Promise<FlagActionState>, fd: FormData, ok: string) =>
    startTransition(async () => {
      const result = await action({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success(ok);
    });

  const onToggle = (row: FlagRow, value: string) => {
    const fd = new FormData();
    fd.set('tenantId', tenantId);
    fd.set('code', row.code);
    fd.set('enabled', value);
    run(setFeature, fd, value === '' ? 'Back to the plan default.' : `${row.label} ${value === 'true' ? 'on' : 'off'}.`);
  };

  const onPlan = (code: string) => {
    const fd = new FormData();
    fd.set('tenantId', tenantId);
    fd.set('planCode', code);
    run(setPlan, fd, 'Plan changed.');
  };

  return (
    <div className="space-y-6" data-testid="feature-flags-view">
      {canEdit ? (
        <Card>
          <CardContent className="flex flex-wrap items-end gap-3 p-5">
            <div className="space-y-2">
              <Label htmlFor="plan-select">Plan</Label>
              <Select value={planCode} onValueChange={onPlan} disabled={pending}>
                <SelectTrigger id="plan-select" className="w-56" data-testid="plan-select">
                  <SelectValue placeholder="No plan" />
                </SelectTrigger>
                <SelectContent>
                  {plans.map((p) => (
                    <SelectItem key={p.code} value={p.code}>
                      {p.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <p className="text-sm text-muted-foreground">
              The plan sets the defaults. An override below wins over it for this school only.
            </p>
          </CardContent>
        </Card>
      ) : null}

      <div className="space-y-3">
        {rows.map((row) => (
          <Card key={row.code} data-testid={`flag-${row.code}`}>
            <CardContent className="flex flex-wrap items-center justify-between gap-4 p-5">
              <div className="min-w-0 space-y-1">
                <div className="flex items-center gap-2">
                  <p className="font-medium">{row.label}</p>
                  {row.isBeta ? <Badge variant="outline">Beta</Badge> : null}
                  <Badge
                    variant={row.enabled ? 'success' : 'outline'}
                    data-testid={`flag-state-${row.code}`}
                  >
                    {row.enabled ? 'On' : 'Off'}
                  </Badge>
                  {row.override !== null ? (
                    <Badge variant="warning" data-testid={`flag-override-${row.code}`}>
                      Overridden
                    </Badge>
                  ) : null}
                </div>
                <p className="text-sm text-muted-foreground">{row.description}</p>
              </div>

              {canEdit ? (
                <div className="flex gap-2">
                  <Button
                    variant={row.enabled ? 'outline' : 'default'}
                    size="sm"
                    disabled={pending}
                    onClick={() => onToggle(row, String(!row.enabled))}
                    data-testid={`flag-toggle-${row.code}`}
                  >
                    Turn {row.enabled ? 'off' : 'on'}
                  </Button>
                  {row.override !== null ? (
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={pending}
                      onClick={() => onToggle(row, '')}
                      data-testid={`flag-clear-${row.code}`}
                    >
                      Use plan default
                    </Button>
                  ) : null}
                </div>
              ) : null}
            </CardContent>
          </Card>
        ))}
      </div>
    </div>
  );
}
