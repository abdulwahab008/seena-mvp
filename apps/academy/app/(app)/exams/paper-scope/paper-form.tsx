'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { requestPaper } from './actions';
import { Button } from '@/components/ui/button';

export type ScopeUnit = { id: string; sequence: number; title: string; taught: boolean };

export function PaperForm({ units, sections }: { units: ScopeUnit[]; sections: { id: string; label: string }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [title, setTitle] = useState('');
  const [sectionId, setSectionId] = useState('');
  const [picked, setPicked] = useState<string[]>(units.filter((u) => u.taught).map((u) => u.id));
  const [override, setOverride] = useState(false);

  const toggle = (id: string) => setPicked((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]));
  const submit = () =>
    startTransition(async () => {
      const r = await requestPaper({ title, unitIds: picked, sectionId, untaughtOverride: override });
      setError(r.error);
      if (!r.error) {
        toast.success('Paper requested.');
        setTitle('');
        router.refresh();
      }
    });

  if (units.length === 0) return <p className="text-sm text-muted-foreground">No syllabus has been defined for this class and subject yet.</p>;
  return (
    <div className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Paper title</span>
          <input value={title} onChange={(e) => setTitle(e.target.value)} className="h-10 w-full rounded-md border bg-background px-3" data-testid="paper-title" />
        </label>
        {sections.length > 0 && (
          <label className="space-y-1 text-sm">
            <span className="block text-muted-foreground">Coverage is checked for</span>
            <select value={sectionId} onChange={(e) => setSectionId(e.target.value)} className="h-10 w-full rounded-md border bg-background px-2">
              <option value="">Any section of the class</option>
              {sections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
          </label>
        )}
      </div>
      <fieldset className="space-y-1" data-testid="scope-picker">
        <legend className="text-sm font-medium">Chapters in scope</legend>
        {units.map((u) => (
          <label key={u.id} className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={picked.includes(u.id)} onChange={() => toggle(u.id)} />
            {u.sequence}. {u.title}
            {!u.taught && <span className="text-xs text-muted-foreground">(not taught yet)</span>}
          </label>
        ))}
      </fieldset>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={override} onChange={(e) => setOverride(e.target.checked)} data-testid="untaught-override" />
        Include untaught chapters (Exam Controller only)
      </label>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="paper-error">
          {error}
        </p>
      )}
      <Button disabled={pending} onClick={submit} data-testid="request-paper">
        Request paper
      </Button>
    </div>
  );
}
