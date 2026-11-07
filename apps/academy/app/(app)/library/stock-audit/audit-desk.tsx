'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { runStockAudit } from './actions';
import type { AuditCopy, AuditResult } from '@/lib/library-stock-audit';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';

const schema = z.object({ scanned: z.string().trim().min(1, 'Scan at least one barcode'), shelf: z.string().trim().max(50) });

function CopyList({ title, copies, testId }: { title: string; copies: AuditCopy[]; testId: string }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">
          {title} ({copies.length})
        </CardTitle>
      </CardHeader>
      <CardContent>
        {copies.length === 0 ? (
          <p className="text-sm text-muted-foreground">None.</p>
        ) : (
          <ul className="space-y-1 text-sm" data-testid={testId}>
            {copies.map((c) => (
              <li key={c.barcode}>
                <span className="font-mono">{c.barcode}</span> · {c.title} · Acc {c.accession_no}
                {c.shelf ? ` · shelf ${c.shelf}` : ''}
                {c.status !== 'available' ? ` · register says ${c.status.replace('_', ' ')}` : ''}
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}

export function AuditDesk({ campusId }: { campusId: string }) {
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<AuditResult | null>(null);
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: { scanned: '', shelf: '' } });

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await runStockAudit({ campusId, scanned: v.scanned, shelf: v.shelf || undefined });
      if (r.error || !r.result) return void toast.error(r.error ?? 'Audit failed.');
      setResult(r.result);
    }),
  );

  return (
    <div className="space-y-4">
      <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-[1fr_12rem]" noValidate>
        <div className="space-y-1">
          <Label htmlFor="audit-scanned">Scanned barcodes</Label>
          <Textarea id="audit-scanned" rows={8} className="font-mono" {...register('scanned')} />
          {errors.scanned && <p className="text-sm text-destructive">{errors.scanned.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="audit-shelf">Only this shelf (optional)</Label>
          <Input id="audit-shelf" {...register('shelf')} />
          <Button type="submit" disabled={pending} className="mt-3 w-full">
            Compare with register
          </Button>
        </div>
      </form>
      {result && (
        <>
          <p className="text-sm" data-testid="audit-summary">
            {result.found} on the shelf as expected · {result.missing.length} missing · {result.notAvailable.length} out on the register · {result.unknown.length} unknown codes
          </p>
          <CopyList title="Missing from the shelf" copies={result.missing} testId="audit-missing" />
          <CopyList title="On the shelf but out on the register (check them in)" copies={result.notAvailable} testId="audit-out" />
          {result.unknown.length > 0 && <p className="text-sm text-muted-foreground">Unknown codes: {result.unknown.join(', ')}</p>}
          <p className="text-xs text-muted-foreground">Mark missing copies lost from Write-offs once they have been searched for.</p>
        </>
      )}
    </div>
  );
}
