'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { generateChallans, type GenerateResult } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type ChallanRow = {
  id: string;
  challanNo: string;
  billingPeriod: string;
  grossPaisa: number;
  concessionPaisa: number;
  netPaisa: number;
  status: string;
};

export type BatchErrorRow = { id: string; reason: string };

export type BatchRow = {
  id: string;
  billingPeriod: string;
  generatedCount: number;
  skippedCount: number;
  failedCount: number;
} | null;

function ResultSummary({ result }: { result: GenerateResult }) {
  if (result.error !== null || result.generated === undefined) return null;
  return (
    <div data-testid="generate-result" className="space-y-1 rounded-lg border p-3 text-sm">
      <p>
        {result.dryRun ? 'Dry run' : 'Generated'}: {result.generated} · Skipped: {result.skipped} · Failed: {result.failed}
      </p>
      {result.dryRun && result.previewByClass && Object.keys(result.previewByClass).length > 0 && (
        <ul className="text-muted-foreground">
          {Object.entries(result.previewByClass).map(([className, netPaisa]) => (
            <li key={className}>
              {className}: PKR {(netPaisa / 100).toLocaleString()}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function ChallanGenerator({
  campusId,
  sessionId,
  batch,
  batchErrors,
  challans,
}: {
  campusId: string;
  sessionId: string;
  batch: BatchRow;
  batchErrors: BatchErrorRow[];
  challans: ChallanRow[];
}) {
  const [pending, startTransition] = useTransition();
  const [period, setPeriod] = useState('');
  const [result, setResult] = useState<GenerateResult>({ error: null });

  const run = (dryRun: boolean) => {
    if (!period) {
      toast.error('Choose a billing month.');
      return;
    }
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('period', period);
    if (dryRun) fd.set('dryRun', 'on');

    startTransition(async () => {
      const outcome = await generateChallans({ error: null }, fd);
      if (outcome.error) toast.error(outcome.error);
      else {
        toast.success(dryRun ? 'Dry run complete.' : 'Challans generated.');
        setResult(outcome);
      }
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="period">Billing month</Label>
          <Input
            id="period"
            type="month"
            data-testid="challan-period-input"
            value={period}
            onChange={(e) => setPeriod(e.target.value)}
          />
        </div>
        <Button type="button" variant="outline" disabled={pending} onClick={() => run(true)} data-testid="dry-run-button">
          {pending ? 'Working…' : 'Dry run'}
        </Button>
        <Button type="button" disabled={pending} onClick={() => run(false)} data-testid="generate-button">
          {pending ? 'Working…' : 'Generate challans'}
        </Button>
      </div>

      <ResultSummary result={result} />

      {batch && (
        <p className="text-sm text-muted-foreground" data-testid="last-batch-summary">
          Last batch ({batch.billingPeriod}): {batch.generatedCount} generated, {batch.skippedCount} skipped, {batch.failedCount} failed
        </p>
      )}

      {batchErrors.length > 0 && (
        <div className="space-y-1">
          <p className="text-sm font-medium">Batch errors</p>
          {batchErrors.map((e) => (
            <p key={e.id} className="text-xs text-destructive">
              {e.reason}
            </p>
          ))}
        </div>
      )}

      <div className="space-y-2">
        {challans.length === 0 ? (
          <p className="text-sm text-muted-foreground">No challans generated yet.</p>
        ) : (
          challans.map((c) => (
            <Card key={c.id} data-testid={`challan-row-${c.challanNo}`}>
              <CardContent className="flex items-center justify-between p-3 text-sm">
                <span>
                  {c.challanNo} · {c.billingPeriod}
                </span>
                <span className="text-muted-foreground">
                  Net PKR {(c.netPaisa / 100).toLocaleString()} · {c.status}
                </span>
              </CardContent>
            </Card>
          ))
        )}
      </div>
    </div>
  );
}
