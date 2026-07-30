'use client';

import { useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createLateFeeRule, previewLateFee } from './actions';
import { LATE_FEE_BASES, createLateFeeRuleSchema, type CreateLateFeeRuleInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type RuleRow = {
  id: string;
  basis: string;
  graceDays: number;
  amountPaisa: number | null;
  percentage: number | null;
  capPaisa: number | null;
  effectiveFrom: string;
};

export type ChallanOption = { id: string; challanNo: string };

function CreateRuleForm({ campusId, sessionId }: { campusId: string; sessionId: string }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    watch,
    formState: { errors },
  } = useForm<CreateLateFeeRuleInput>({
    resolver: zodResolver(createLateFeeRuleSchema),
    defaultValues: { campusId, sessionId, basis: 'per_day', graceDays: 3 },
  });
  const basis = watch('basis');

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('basis', values.basis);
    fd.set('graceDays', String(values.graceDays));
    if (values.amountRupees !== undefined) fd.set('amountRupees', String(values.amountRupees));
    if (values.percentage !== undefined) fd.set('percentage', String(values.percentage));
    if (values.capRupees !== undefined) fd.set('capRupees', String(values.capRupees));

    startTransition(async () => {
      const result = await createLateFeeRule({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Rule created.');
        reset({ campusId, sessionId, basis: 'per_day', graceDays: 3 });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="basis">Basis</Label>
        <Controller
          control={control}
          name="basis"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="late-fee-basis-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {LATE_FEE_BASES.map((b) => (
                  <SelectItem key={b} value={b}>
                    {b.replace(/_/g, ' ')}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="graceDays">Grace days</Label>
        <Input id="graceDays" type="number" {...register('graceDays')} />
        {errors.graceDays && <p className="text-xs text-destructive">{errors.graceDays.message}</p>}
      </div>
      {basis === 'percentage' ? (
        <div className="space-y-1">
          <Label htmlFor="percentage">Percentage</Label>
          <Input id="percentage" type="number" step="0.01" placeholder="2" {...register('percentage')} />
          {errors.percentage && <p className="text-xs text-destructive">{errors.percentage.message}</p>}
        </div>
      ) : (
        <div className="space-y-1">
          <Label htmlFor="amountRupees">Amount (PKR)</Label>
          <Input id="amountRupees" type="number" placeholder="50" {...register('amountRupees')} />
          {errors.amountRupees && <p className="text-xs text-destructive">{errors.amountRupees.message}</p>}
        </div>
      )}
      <div className="space-y-1">
        <Label htmlFor="capRupees">Cap (PKR, optional)</Label>
        <Input id="capRupees" type="number" placeholder="1000" {...register('capRupees')} />
      </div>
      <Button type="submit" disabled={pending} className="col-span-2 w-fit md:col-span-1" data-testid="create-late-fee-rule-button">
        {pending ? 'Creating…' : 'Create rule'}
      </Button>
    </form>
  );
}

function PreviewPanel({ challans }: { challans: ChallanOption[] }) {
  const [pending, startTransition] = useTransition();
  const [challanId, setChallanId] = useState('');
  const [asOf, setAsOf] = useState('');
  const [amountPaisa, setAmountPaisa] = useState<number | null>(null);

  const onPreview = () => {
    if (!challanId || !asOf) {
      toast.error('Choose a challan and a date.');
      return;
    }
    const fd = new FormData();
    fd.set('challanId', challanId);
    fd.set('asOf', asOf);
    startTransition(async () => {
      const result = await previewLateFee({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else setAmountPaisa(result.amountPaisa ?? 0);
    });
  };

  return (
    <div className="space-y-2 rounded-lg border p-4">
      <p className="text-sm font-medium">Preview a late fee</p>
      <div className="flex flex-wrap items-end gap-2">
        <div className="space-y-1">
          <Label htmlFor="challanId">Challan</Label>
          <Select value={challanId} onValueChange={setChallanId}>
            <SelectTrigger data-testid="preview-challan-trigger" className="w-48">
              <SelectValue placeholder="Select a challan" />
            </SelectTrigger>
            <SelectContent>
              {challans.map((c) => (
                <SelectItem key={c.id} value={c.id}>
                  {c.challanNo}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="asOf">As of</Label>
          <Input id="asOf" type="date" data-testid="preview-as-of-input" value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        </div>
        <Button type="button" disabled={pending} onClick={onPreview} data-testid="preview-late-fee-button">
          {pending ? 'Computing…' : 'Preview'}
        </Button>
      </div>
      {amountPaisa !== null && (
        <p data-testid="late-fee-preview-result" className="text-sm">
          Late fee: PKR {(amountPaisa / 100).toLocaleString()}
        </p>
      )}
    </div>
  );
}

export function LateFeeRuleView({
  campusId,
  sessionId,
  rules,
  challans,
  canConfigure,
}: {
  campusId: string;
  sessionId: string;
  rules: RuleRow[];
  challans: ChallanOption[];
  canConfigure: boolean;
}) {
  return (
    <div className="space-y-4">
      {canConfigure && <CreateRuleForm campusId={campusId} sessionId={sessionId} />}

      <div className="space-y-2">
        {rules.length === 0 ? (
          <p className="text-sm text-muted-foreground">No late fee rules configured yet.</p>
        ) : (
          rules.map((r) => (
            <Card key={r.id} data-testid={`late-fee-rule-row-${r.id}`}>
              <CardContent className="flex items-center justify-between p-3 text-sm">
                <span>
                  {r.basis.replace(/_/g, ' ')} · {r.graceDays} grace days · effective {r.effectiveFrom}
                </span>
                <span className="text-muted-foreground">
                  {r.basis === 'percentage' ? `${r.percentage}%` : `PKR ${((r.amountPaisa ?? 0) / 100).toLocaleString()}`}
                  {r.capPaisa !== null && ` · capped at PKR ${(r.capPaisa / 100).toLocaleString()}`}
                </span>
              </CardContent>
            </Card>
          ))
        )}
      </div>

      <PreviewPanel challans={challans} />
    </div>
  );
}
