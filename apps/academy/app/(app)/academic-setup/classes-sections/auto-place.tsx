'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { autoPlaceStudents } from './actions';

export function AutoPlace({ sessionId, classes, students }: { sessionId: string; classes: { id: string; name: string }[]; students: { id: string; name: string; gr: string }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [classId, setClassId] = useState('');
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const toggle = (id: string) =>
    setPicked((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  const place = () =>
    startTransition(async () => {
      const r = await autoPlaceStudents(classId, sessionId, [...picked]);
      setError(r.error);
      if (!r.error) {
        toast.success(r.message);
        setPicked(new Set());
        router.refresh();
      }
    });
  return (
    <div className="space-y-3 text-sm" data-testid="auto-place">
      <ul className="grid max-h-64 gap-1 overflow-y-auto sm:grid-cols-2">
        {students.map((s) => (
          <li key={s.id}>
            <label className="flex items-center gap-2">
              <input type="checkbox" checked={picked.has(s.id)} onChange={() => toggle(s.id)} aria-label={`Place ${s.name}`} />
              {s.name} <span className="text-muted-foreground">({s.gr})</span>
            </label>
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap items-center gap-2">
        <select aria-label="Class to place them in" className="h-9 rounded-md border bg-background px-2" value={classId} onChange={(e) => setClassId(e.target.value)}>
          <option value="">Choose class</option>
          {classes.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
        <Button size="sm" disabled={pending || picked.size === 0} onClick={place} data-testid="auto-place-submit">
          Place {picked.size || ''} in the emptiest sections
        </Button>
      </div>
      {error && <p role="alert" className="text-destructive">{error}</p>}
    </div>
  );
}
