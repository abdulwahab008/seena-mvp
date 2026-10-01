'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { generatePlan, setDeskAvailable, setPaperSets } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';

export function SlotPlanner({ slotId, examSubjectId, hallId, setCount }: { slotId: string; examSubjectId: string; hallId: string | null; setCount: number }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [strategy, setStrategy] = useState<'interleave' | 'sequential'>('interleave');
  const [sets, setSets] = useState(setCount);
  const [desk, setDesk] = useState({ row: '', seat: '' });
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Paper sets</span>
          <select
            aria-label="Paper sets"
            className="h-9 rounded-md border bg-background px-2"
            value={sets}
            onChange={(e) => {
              const n = Number(e.target.value);
              setSets(n);
              startTransition(async () => {
                const r = await setPaperSets(examSubjectId, n);
                setError(r.error);
                if (!r.error) router.refresh();
              });
            }}
          >
            {[1, 2, 3, 4].map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Strategy</span>
          <select aria-label="Strategy" className="h-9 rounded-md border bg-background px-2" value={strategy} onChange={(e) => setStrategy(e.target.value as 'interleave' | 'sequential')}>
            <option value="interleave">Interleave sections</option>
            <option value="sequential">Roll order</option>
          </select>
        </label>
        <Button
          disabled={pending || !hallId}
          data-testid="generate-plan"
          onClick={() =>
            startTransition(async () => {
              const r = await generatePlan(slotId, strategy);
              setError(r.error);
              setMessage(r.error ? null : `${r.seated} candidates seated. ${r.violations === 0 ? 'No adjacency violations.' : `${r.violations} adjacency violation(s).`}`);
              if (!r.error) {
                toast.success('Seating plan generated.');
                router.refresh();
              }
            })
          }
        >
          Generate / update plan
        </Button>
        <a className="text-sm underline" href={`/api/seating/${slotId}/pdf?kind=chart`} target="_blank" rel="noreferrer">
          Seating chart (PDF)
        </a>
        <a className="text-sm underline" href={`/api/seating/${slotId}/pdf?kind=slips`} target="_blank" rel="noreferrer">
          Seat slips (PDF)
        </a>
      </div>
      {!hallId && <p className="text-sm text-muted-foreground">Assign a hall to this paper on the datesheet to generate a plan.</p>}
      {message && <p className="text-sm" data-testid="plan-message">{message}</p>}
      {error && <p role="alert" className="text-sm text-destructive" data-testid="plan-error">{error}</p>}
      {hallId && (
        <div className="flex flex-wrap items-center gap-2 text-sm">
          <span className="text-muted-foreground">Desk out of use:</span>
          <Input aria-label="Desk row" className="h-8 w-20" placeholder="Row" value={desk.row} onChange={(e) => setDesk({ ...desk, row: e.target.value })} />
          <Input aria-label="Desk seat" className="h-8 w-20" placeholder="Seat" value={desk.seat} onChange={(e) => setDesk({ ...desk, seat: e.target.value })} />
          <Button
            size="sm"
            variant="outline"
            disabled={pending || !desk.row || !desk.seat}
            onClick={() =>
              startTransition(async () => {
                const r = await setDeskAvailable(hallId, Number(desk.row), Number(desk.seat), false);
                setError(r.error);
                if (!r.error) {
                  toast.success('Desk marked out of use; regenerate the plan.');
                  setDesk({ row: '', seat: '' });
                  router.refresh();
                }
              })
            }
          >
            Mark unusable
          </Button>
        </div>
      )}
    </div>
  );
}
