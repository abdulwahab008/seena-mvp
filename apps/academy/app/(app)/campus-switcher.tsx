'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { setActiveCampus } from './campus-actions';

export type CampusOption = { id: string; name: string };

export function CampusSwitcher({ campuses, activeId }: { campuses: CampusOption[]; activeId: string | null }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  if (campuses.length < 2) return null;
  return (
    <label className="flex items-center gap-2 text-sm">
      <span className="sr-only sm:not-sr-only sm:text-muted-foreground">Campus</span>
      <select
        className="h-9 max-w-[12rem] truncate rounded-md border bg-background px-2 text-sm"
        value={activeId ?? ''}
        disabled={pending}
        data-testid="campus-switcher"
        onChange={(e) => {
          const id = e.target.value;
          startTransition(async () => {
            const r = await setActiveCampus(id);
            if (r.error) toast.error(r.error);
            else router.refresh();
          });
        }}
      >
        {campuses.map((c) => (
          <option key={c.id} value={c.id}>
            {c.name}
          </option>
        ))}
      </select>
    </label>
  );
}
