'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { libraryCopySchema, type LibraryCopyInput } from '@/lib/validation';
import { COPY_IMPORT_HEADER } from '@/lib/library';
import { importCopies, registerCopy, setCopyStatus, type ImportReport } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

type Campus = { id: string; name: string };

export function RegisterCopyForm({ titleId, campuses }: { titleId: string; campuses: Campus[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<LibraryCopyInput>({
    resolver: zodResolver(libraryCopySchema),
    defaultValues: { titleId, campusId: campuses[0]?.id ?? '', accessionNo: '', barcode: '', shelf: '', purchaseCostPkr: '', acquiredOn: '' },
  });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await registerCopy(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Copy registered.');
        form.reset({ ...v, accessionNo: '', barcode: '' });
        router.refresh();
      }
    }),
  );
  const text = (name: keyof LibraryCopyInput, label: string, type = 'text') => (
    <div className="space-y-1">
      <Label htmlFor={`copy-${name}`}>{label}</Label>
      <Input id={`copy-${name}`} type={type} {...form.register(name)} />
      {form.formState.errors[name] && <p className="text-xs text-destructive">{String(form.formState.errors[name]?.message)}</p>}
    </div>
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-3 md:grid-cols-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="copy-campusId">Campus</Label>
        <select id="copy-campusId" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('campusId')}>
          {campuses.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
      </div>
      {text('accessionNo', 'Accession number')}
      {text('barcode', 'Barcode')}
      {text('shelf', 'Shelf')}
      {text('purchaseCostPkr', 'Purchase cost (PKR)')}
      {text('acquiredOn', 'Acquired on', 'date')}
      <div className="flex items-end gap-3 md:col-span-3">
        <Button type="submit" disabled={pending} data-testid="register-copy">
          Register copy
        </Button>
        {error && (
          <p role="alert" className="text-sm text-destructive" data-testid="copy-error">
            {error}
          </p>
        )}
      </div>
    </form>
  );
}

export function ImportCopiesForm({ campuses }: { campuses: Campus[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [campusId, setCampusId] = useState(campuses[0]?.id ?? '');
  const [report, setReport] = useState<ImportReport | null>(null);
  return (
    <form
      className="space-y-3"
      onSubmit={(e) => {
        e.preventDefault();
        const file = (e.currentTarget.elements.namedItem('csv') as HTMLInputElement).files?.[0];
        if (!file) {
          setReport({ ok: false, imported: 0, problems: ['Choose a CSV file.'] });
          return;
        }
        startTransition(async () => {
          const text = await file.text();
          const r = await importCopies(campusId, text);
          setReport(r);
          if (r.ok) {
            toast.success(`${r.imported} copies imported.`);
            router.refresh();
          }
        });
      }}
    >
      <p className="text-xs text-muted-foreground">
        CSV columns: <code>{COPY_IMPORT_HEADER.join(', ')}</code>. Either isbn or title_id identifies the title. The import is all-or-nothing.
      </p>
      <div className="flex flex-wrap items-end gap-3">
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Campus</span>
          <select value={campusId} onChange={(e) => setCampusId(e.target.value)} className="h-9 rounded-md border bg-background px-2" aria-label="Import campus">
            {campuses.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <input type="file" name="csv" accept=".csv,text/csv" aria-label="Copies CSV" className="text-sm" />
        <Button type="submit" variant="outline" disabled={pending} data-testid="import-copies">
          Import
        </Button>
      </div>
      {report && !report.ok && (
        <ul role="alert" className="list-disc pl-5 text-sm text-destructive" data-testid="import-problems">
          <li className="list-none font-medium">Nothing was imported.</li>
          {report.problems.slice(0, 50).map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      )}
      {report?.ok && <p className="text-sm text-muted-foreground">{report.imported} copies imported.</p>}
    </form>
  );
}

export function CopyStatusButtons({ copyId, status }: { copyId: string; status: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const move = (next: 'available' | 'in_repair' | 'lost') =>
    startTransition(async () => {
      const r = await setCopyStatus(copyId, next);
      setError(r.error);
      if (!r.error) router.refresh();
    });
  return (
    <span className="flex flex-wrap items-center gap-1">
      {status === 'available' && (
        <Button size="sm" variant="outline" disabled={pending} onClick={() => move('in_repair')}>
          Send to repair
        </Button>
      )}
      {(status === 'available' || status === 'in_repair') && (
        <Button size="sm" variant="outline" disabled={pending} onClick={() => move('lost')}>
          Mark lost
        </Button>
      )}
      {(status === 'in_repair' || status === 'lost') && (
        <Button size="sm" disabled={pending} onClick={() => move('available')} data-testid="restore-copy">
          {status === 'lost' ? 'Found: back on shelf' : 'Repaired: back on shelf'}
        </Button>
      )}
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}
