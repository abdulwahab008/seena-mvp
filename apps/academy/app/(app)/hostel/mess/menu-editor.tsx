'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { publishMenu, saveMenu } from './actions';

export type MenuSlot = { day: number; meal: 'breakfast' | 'lunch' | 'dinner'; items: string; items_ur: string };

const DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const MEALS = ['breakfast', 'lunch', 'dinner'] as const;
const CONTROL = 'h-9 w-full rounded-md border bg-background px-2 text-sm';

/** The 7 x 3 grid for a week; English and Urdu per slot. Save keeps a draft, Publish needs all 21. */
export function MenuEditor({ campusId, weekStart, initial, published }: { campusId: string; weekStart: string; initial: MenuSlot[]; published: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [slots, setSlots] = useState<MenuSlot[]>(() =>
    DAYS.flatMap((_, d) => MEALS.map((meal) => initial.find((s) => s.day === d + 1 && s.meal === meal) ?? { day: d + 1, meal, items: '', items_ur: '' })),
  );
  const set = (day: number, meal: string, key: 'items' | 'items_ur', value: string) =>
    setSlots((prev) => prev.map((s) => (s.day === day && s.meal === meal ? { ...s, [key]: value } : s)));

  const run = (fn: () => Promise<{ error: string | null; message?: string }>) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) {
        toast.success(r.message ?? 'Done.');
        router.refresh();
      }
    });

  return (
    <div className="space-y-3" data-testid="menu-editor">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-muted-foreground">
              <th className="py-1">Day</th>
              {MEALS.map((m) => (
                <th key={m} className="capitalize">
                  {m}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {DAYS.map((name, d) => (
              <tr key={name} className="border-t align-top">
                <td className="py-2 pe-2 font-medium">{name}</td>
                {MEALS.map((meal) => {
                  const s = slots.find((x) => x.day === d + 1 && x.meal === meal)!;
                  return (
                    <td key={meal} className="space-y-1 py-2 pe-2">
                      <input aria-label={`${name} ${meal}`} className={CONTROL} value={s.items} disabled={published} onChange={(e) => set(d + 1, meal, 'items', e.target.value)} />
                      <input aria-label={`${name} ${meal} (Urdu)`} dir="rtl" className={CONTROL} value={s.items_ur} disabled={published} onChange={(e) => set(d + 1, meal, 'items_ur', e.target.value)} />
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="menu-error">
          {error}
        </p>
      )}
      {!published && (
        <div className="flex gap-2">
          <Button type="button" size="sm" variant="outline" disabled={pending} data-testid="save-menu" onClick={() => run(() => saveMenu({ campusId, weekStart, slots: JSON.stringify(slots) }))}>
            Save draft
          </Button>
          <Button
            type="button"
            size="sm"
            disabled={pending}
            data-testid="publish-menu"
            onClick={() =>
              run(async () => {
                const saved = await saveMenu({ campusId, weekStart, slots: JSON.stringify(slots) });
                return saved.error ? saved : publishMenu({ campusId, weekStart });
              })
            }
          >
            Publish week
          </Button>
        </div>
      )}
    </div>
  );
}
