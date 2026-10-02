'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { saveCoverage } from './actions';
import { Button } from '@/components/ui/button';

export type CoverageUnit = {
  unitId: string;
  sequence: number;
  title: string;
  plannedPeriods: number;
  status: 'not_started' | 'in_progress' | 'completed';
  startedOn: string | null;
  completedOn: string | null;
  periodsUsed: number;
  inferred: boolean;
};

export function CoverageRow({ sectionId, subjectId, unit }: { sectionId: string; subjectId: string; unit: CoverageUnit }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState(unit.status);
  const [startedOn, setStartedOn] = useState(unit.startedOn ?? '');
  const [completedOn, setCompletedOn] = useState(unit.completedOn ?? '');
  const [periods, setPeriods] = useState(String(unit.periodsUsed));

  const save = () =>
    startTransition(async () => {
      const r = await saveCoverage({
        sectionId,
        subjectId,
        unitId: unit.unitId,
        status,
        startedOn: status === 'not_started' ? '' : startedOn,
        completedOn: status === 'completed' ? completedOn : '',
        periodsUsed: periods === '' ? undefined : Number(periods),
      });
      setError(r.error);
      if (!r.error) {
        toast.success('Coverage saved.');
        router.refresh();
      }
    });

  return (
    <tr className="border-b align-top" data-testid="coverage-row">
      <td className="py-2 pr-2">
        {unit.sequence}. {unit.title}
        <span className="block text-xs text-muted-foreground">{unit.plannedPeriods} planned periods</span>
        {unit.inferred && <span className="block text-xs text-muted-foreground">start date inferred</span>}
      </td>
      <td className="pr-2">
        <select aria-label={`Status of ${unit.title}`} value={status} onChange={(e) => setStatus(e.target.value as CoverageUnit['status'])} className="h-9 rounded-md border bg-background px-2">
          <option value="not_started">Not started</option>
          <option value="in_progress">In progress</option>
          <option value="completed">Completed</option>
        </select>
      </td>
      <td className="pr-2">
        <input type="date" aria-label={`Started on for ${unit.title}`} value={startedOn} disabled={status === 'not_started'} onChange={(e) => setStartedOn(e.target.value)} className="h-9 rounded-md border bg-background px-2" />
      </td>
      <td className="pr-2">
        <input type="date" aria-label={`Completed on for ${unit.title}`} value={completedOn} disabled={status !== 'completed'} onChange={(e) => setCompletedOn(e.target.value)} className="h-9 rounded-md border bg-background px-2" />
      </td>
      <td className="pr-2">
        <input type="number" min={0} aria-label={`Periods used for ${unit.title}`} value={periods} onChange={(e) => setPeriods(e.target.value)} className="h-9 w-20 rounded-md border bg-background px-2" />
      </td>
      <td>
        <Button size="sm" disabled={pending} onClick={save} data-testid="save-coverage">
          Save
        </Button>
        {error && (
          <p role="alert" className="mt-1 max-w-[12rem] text-xs text-destructive" data-testid="coverage-error">
            {error}
          </p>
        )}
      </td>
    </tr>
  );
}
