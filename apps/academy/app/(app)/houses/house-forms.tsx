'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { houseMoveSchema, housePointsSchema, houseSchema, type HouseInput, type HouseMoveInput, type HousePointsInput } from '@/lib/validation';
import { autoAssign, awardPoints, createHouse, deleteHouse, moveStudent, setBalancing, type AutoAssignResult } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

function useRun() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (fn: () => Promise<{ error: string | null }>, ok?: string) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) {
        if (ok) toast.success(ok);
        router.refresh();
      }
    });
  return { pending, error, run };
}

export type HouseOption = { id: string; name: string };
const today = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

export function HouseForm({ campusId }: { campusId: string }) {
  const { pending, error, run } = useRun();
  const form = useForm<HouseInput>({ resolver: zodResolver(houseSchema), defaultValues: { name: '', colourHex: '#3b82f6', motto: '' } });
  const onSubmit = form.handleSubmit((v) =>
    run(async () => {
      const r = await createHouse(campusId, v);
      if (!r.error) form.reset();
      return r;
    }, 'House created.'),
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="houseName">House name</Label>
        <Input id="houseName" {...form.register('name')} />
        {form.formState.errors.name && <p className="text-xs text-destructive">{form.formState.errors.name.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="houseColour">Colour</Label>
        <Input id="houseColour" type="color" className="p-1" {...form.register('colourHex')} />
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="houseMotto">Motto (optional)</Label>
        <Input id="houseMotto" {...form.register('motto')} />
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-4" data-testid="house-error">{error}</p>}
      <div className="sm:col-span-4">
        <Button type="submit" disabled={pending} data-testid="create-house">
          Add house
        </Button>
      </div>
    </form>
  );
}

export function AutoAssignPanel({ campusId, sessionId, balancing }: { campusId: string; sessionId: string; balancing: boolean }) {
  const { pending, error, run } = useRun();
  const [summary, setSummary] = useState<AutoAssignResult['summary'] | null>(null);
  return (
    <div className="space-y-3 text-sm">
      <label className="flex items-center gap-2">
        <input type="checkbox" defaultChecked={balancing} disabled={pending} onChange={(e) => run(() => setBalancing(campusId, e.target.checked), 'Setting saved.')} data-testid="balancing-toggle" />
        Balance house sizes (least-populated house first)
      </label>
      <Button
        disabled={pending}
        data-testid="auto-assign"
        onClick={() =>
          run(async () => {
            const r = await autoAssign(campusId, sessionId);
            setSummary(r.summary ?? null);
            return r;
          })
        }
      >
        Auto-assign un-housed students
      </Button>
      {summary && (
        <p data-testid="auto-assign-result" className="text-muted-foreground">
          Placed {summary.assigned} students: {summary.siblingMatch} with a sibling, {summary.balanced} balanced, {summary.spread} spread.
        </p>
      )}
      {error && <p role="alert" className="text-destructive">{error}</p>}
    </div>
  );
}

export function DeleteHouseButton({ houseId }: { houseId: string }) {
  const { pending, error, run } = useRun();
  return (
    <span>
      <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => deleteHouse(houseId), 'House deleted.')}>
        Delete
      </Button>
      {error && <span role="alert" className="ml-2 text-xs text-destructive">{error}</span>}
    </span>
  );
}

export function MoveForm({ houses }: { houses: HouseOption[] }) {
  const { pending, error, run } = useRun();
  const form = useForm<HouseMoveInput>({ resolver: zodResolver(houseMoveSchema), defaultValues: { grNumber: '', houseId: houses[0]?.id ?? '', effectiveDate: today() } });
  const onSubmit = form.handleSubmit((v) => run(() => moveStudent(v), 'Student moved.'));
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="moveGr">GR number</Label>
        <Input id="moveGr" {...form.register('grNumber')} />
        {form.formState.errors.grNumber && <p className="text-xs text-destructive">{form.formState.errors.grNumber.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="moveHouse">New house</Label>
        <select id="moveHouse" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('houseId')}>
          {houses.map((h) => (
            <option key={h.id} value={h.id}>
              {h.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="moveDate">Effective from</Label>
        <Input id="moveDate" type="date" {...form.register('effectiveDate')} />
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-4" data-testid="move-error">{error}</p>}
      <div className="sm:col-span-4">
        <Button type="submit" disabled={pending || houses.length === 0} data-testid="move-student">
          Move student
        </Button>
      </div>
    </form>
  );
}

export function PointsForm() {
  const { pending, error, run } = useRun();
  const form = useForm<HousePointsInput>({ resolver: zodResolver(housePointsSchema), defaultValues: { grNumber: '', points: 5, awardedOn: today(), category: 'sports', note: '' } });
  const onSubmit = form.handleSubmit((v) => run(() => awardPoints(v), 'Points recorded.'));
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-5" noValidate>
      <div className="space-y-1">
        <Label htmlFor="ptGr">GR number</Label>
        <Input id="ptGr" {...form.register('grNumber')} />
        {form.formState.errors.grNumber && <p className="text-xs text-destructive">{form.formState.errors.grNumber.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ptPoints">Points</Label>
        <Input id="ptPoints" type="number" {...form.register('points', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="ptDate">Date earned</Label>
        <Input id="ptDate" type="date" {...form.register('awardedOn')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="ptCat">Category</Label>
        <select id="ptCat" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('category')}>
          <option value="sports">Sports</option>
          <option value="academic">Academic</option>
          <option value="discipline">Discipline</option>
          <option value="other">Other</option>
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="ptNote">Note</Label>
        <Input id="ptNote" {...form.register('note')} />
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-5" data-testid="points-error">{error}</p>}
      <div className="sm:col-span-5">
        <Button type="submit" disabled={pending} data-testid="award-points">
          Record points
        </Button>
      </div>
    </form>
  );
}
