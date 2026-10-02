'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { generateCensusReturn } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type Option = { value: string; label: string };

export function CensusForm({ campuses, frameworks }: { campuses: Option[]; frameworks: Option[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [campusId, setCampusId] = useState(campuses[0]?.value ?? '');
  const [framework, setFramework] = useState(frameworks[0]?.value ?? 'punjab_emis');
  const [censusDate, setCensusDate] = useState('');
  const select = 'h-10 w-full rounded-md border bg-background px-3 text-sm';
  const submit = () =>
    startTransition(async () => {
      setError(null);
      const r = await generateCensusReturn({ campusId, framework: framework as 'punjab_emis', censusDate });
      if (r.error) setError(r.error);
      else {
        toast.success(r.incomplete ? 'Return generated, but flagged incomplete: some students have no usable birth date.' : 'Return generated.');
        router.refresh();
      }
    });
  return (
    <div className="grid gap-4 sm:grid-cols-3" data-testid="census-form">
      <div className="space-y-1">
        <Label htmlFor="campus">Campus</Label>
        <select id="campus" className={select} value={campusId} onChange={(e) => setCampusId(e.target.value)}>
          {campuses.map((c) => (
            <option key={c.value} value={c.value}>
              {c.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="framework">Return format</Label>
        <select id="framework" className={select} value={framework} onChange={(e) => setFramework(e.target.value)}>
          {frameworks.map((f) => (
            <option key={f.value} value={f.value}>
              {f.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="censusDate">Census date</Label>
        <Input id="censusDate" type="date" value={censusDate} onChange={(e) => setCensusDate(e.target.value)} />
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive sm:col-span-3" data-testid="census-error">
          {error}
        </p>
      )}
      <div className="sm:col-span-3">
        <Button type="button" disabled={pending || !censusDate || !campusId} onClick={submit} data-testid="generate-census">
          {pending ? 'Generating…' : 'Generate return'}
        </Button>
      </div>
    </div>
  );
}
