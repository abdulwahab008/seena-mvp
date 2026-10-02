import * as React from 'react';
import { cn } from '@/lib/utils';

/**
 * Loading placeholder. Always give it the size of the thing it stands in for —
 * a skeleton that changes shape when real content arrives reads as a layout bug.
 */
export function Skeleton({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn('relative overflow-hidden rounded-md bg-muted', className)}
      aria-hidden
      {...props}
    >
      <div className="absolute inset-0 -translate-x-full animate-shimmer bg-gradient-to-r from-transparent via-background/60 to-transparent" />
    </div>
  );
}

/** Skeleton shaped like a table body, so a loading table keeps its column rhythm. */
export function SkeletonRows({ rows = 5, cols = 4 }: { rows?: number; cols?: number }) {
  return (
    <div className="divide-y divide-border" data-testid="skeleton-rows">
      {Array.from({ length: rows }).map((_, r) => (
        <div key={r} className="flex items-center gap-4 px-4 py-3">
          {Array.from({ length: cols }).map((_, c) => (
            <Skeleton key={c} className={cn('h-4', c === 0 ? 'w-[22%]' : 'flex-1')} />
          ))}
        </div>
      ))}
    </div>
  );
}
