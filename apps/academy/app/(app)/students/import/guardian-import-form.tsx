'use client';

import { useRef, useState, useTransition } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { GUARDIAN_IMPORT_TEMPLATE } from '@/lib/guardian-import';
import { importGuardianContacts, type GuardianImportResult } from './actions';

export function GuardianImportForm() {
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<GuardianImportResult | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  return (
    <form
      className="space-y-4 rounded-lg border p-4"
      data-testid="guardian-import-form"
      action={(formData) =>
        startTransition(async () => {
          const r = await importGuardianContacts(formData);
          setResult(r);
          if (!r.error) {
            toast.success(`Linked ${r.linked} father${r.linked === 1 ? '' : 's'}.`);
            if (fileRef.current) fileRef.current.value = '';
          }
        })
      }
    >
      <div>
        <h2 className="text-lg font-medium">Link fathers to existing students</h2>
        <p className="text-sm text-muted-foreground">
          One row per student, matched by GR number. Siblings with the same father&apos;s CNIC share one guardian record, which is
          what sibling discounts, the parent portal and fee messages use.
        </p>
      </div>
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <Label htmlFor="guardian-import-file">Guardian file (.csv)</Label>
          <Input id="guardian-import-file" ref={fileRef} name="file" type="file" accept=".csv,text/csv" />
        </div>
        <Button type="submit" disabled={pending} data-testid="guardian-import-submit">
          {pending ? 'Linking…' : 'Link fathers'}
        </Button>
        <a
          href={`data:text/csv;charset=utf-8,${encodeURIComponent(GUARDIAN_IMPORT_TEMPLATE)}`}
          download="guardian-import-template.csv"
          className="text-sm underline"
        >
          Download the template
        </a>
      </div>
      {result?.error && (
        <p role="alert" className="text-sm text-destructive">
          {result.error}
        </p>
      )}
      {result && !result.error && (
        <div className="space-y-2" data-testid="guardian-import-result">
          <p className="text-sm">
            {result.linked} linked · {result.failed} not linked
          </p>
          {result.errors.length > 0 && (
            <ul className="max-h-64 space-y-1 overflow-auto text-sm">
              {result.errors.slice(0, 200).map((e) => (
                <li key={`${e.row}-${e.gr_number}`}>
                  Row {e.row} (GR {e.gr_number || '—'}): {e.message}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </form>
  );
}
