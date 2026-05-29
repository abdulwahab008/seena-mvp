'use client';

import Link from 'next/link';
import { FORMAT_LABELS, type Format } from '@seena/shared';
import { cn } from '@/lib/utils';

type Props = {
  active: Format | null;
  formats: Format[];
};

export function PatternFilter({ active, formats }: Props) {
  return (
    <div className="flex flex-wrap gap-2">
      <Link
        href="/settings/patterns"
        className={cn(
          'rounded-md border px-3 py-1.5 text-xs font-medium transition-colors',
          active === null
            ? 'border-primary bg-primary text-primary-foreground'
            : 'bg-background hover:bg-accent',
        )}
      >
        All
      </Link>
      {formats.map((f) => (
        <Link
          key={f}
          href={`/settings/patterns?format=${f}`}
          className={cn(
            'rounded-md border px-3 py-1.5 text-xs font-medium transition-colors',
            active === f
              ? 'border-primary bg-primary text-primary-foreground'
              : 'bg-background hover:bg-accent',
          )}
        >
          {FORMAT_LABELS[f]}
        </Link>
      ))}
    </div>
  );
}
