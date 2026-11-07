'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { addStandardTraits, saveRatings } from './actions';

const RATINGS = ['', 'A', 'B', 'C', 'D', 'E'] as const;

export function SetupTraitsButton() {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await addStandardTraits();
          if (r.error) toast.error(r.error);
        })
      }
    >
      Add the standard traits
    </Button>
  );
}

export function BehaviourGrid({
  termId,
  traits,
  students,
  initial,
}: {
  termId: string;
  traits: { id: string; name: string }[];
  students: { id: string; rollNo: number | null; name: string }[];
  initial: Record<string, string>;
}) {
  const [pending, startTransition] = useTransition();
  const keys = students.flatMap((s) => traits.map((t) => `${s.id}:${t.id}`));
  const { register, handleSubmit, formState: { dirtyFields } } = useForm<Record<string, string>>({
    defaultValues: Object.fromEntries(keys.map((k) => [k.replace(':', '_'), initial[k] ?? ''])),
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const ratings = Object.keys(dirtyFields).map((k) => {
        const [enrolmentId, traitId] = k.split('_') as [string, string];
        return { enrolmentId, traitId, rating: v[k] ?? '' };
      });
      if (ratings.length === 0) return void toast.info('Nothing changed.');
      const r = await saveRatings({ termId, ratings });
      if (r.error) return void toast.error(r.error);
      toast.success('Ratings saved.');
    }),
  );
  return (
    <form onSubmit={onSubmit} className="space-y-3">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Student</TableHead>
            {traits.map((t) => (
              <TableHead key={t.id} className="text-center">
                {t.name}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {students.map((s) => (
            <TableRow key={s.id}>
              <TableCell>
                {s.rollNo ? `${s.rollNo}. ` : ''}
                {s.name}
              </TableCell>
              {traits.map((t) => (
                <TableCell key={t.id} className="text-center">
                  <select aria-label={`${t.name} for ${s.name}`} className="h-9 rounded-md border bg-background px-2" {...register(`${s.id}_${t.id}`)}>
                    {RATINGS.map((r) => (
                      <option key={r} value={r}>
                        {r || '–'}
                      </option>
                    ))}
                  </select>
                </TableCell>
              ))}
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <Button type="submit" disabled={pending}>
        Save ratings
      </Button>
    </form>
  );
}
