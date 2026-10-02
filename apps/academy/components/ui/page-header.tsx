import * as React from 'react';
import { cn } from '@/lib/utils';

/**
 * Every module page opens with one of these, so title, context line and the
 * primary action sit in the same place on every screen.
 */
export function PageHeader({
  title,
  description,
  actions,
  className,
  children,
  ...props
}: Omit<React.HTMLAttributes<HTMLDivElement>, 'title'> & {
  title: React.ReactNode;
  description?: React.ReactNode;
  actions?: React.ReactNode;
}) {
  return (
    <div className={cn('mb-6 space-y-4', className)} {...props}>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 space-y-1">
          <h1 className="text-xl font-semibold tracking-tight text-foreground sm:text-2xl">{title}</h1>
          {description ? (
            <p className="max-w-3xl text-sm leading-relaxed text-muted-foreground">{description}</p>
          ) : null}
        </div>
        {actions ? <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div> : null}
      </div>
      {children}
    </div>
  );
}

/** A labelled figure for KPI rows and page summaries. */
export function Stat({
  label,
  value,
  hint,
  tone = 'default',
  icon: Icon,
  className,
}: {
  label: string;
  value: React.ReactNode;
  hint?: React.ReactNode;
  tone?: 'default' | 'success' | 'warning' | 'destructive';
  icon?: React.ComponentType<{ className?: string }>;
  className?: string;
}) {
  const toneClass = {
    default: 'text-foreground',
    success: 'text-success',
    warning: 'text-warning',
    destructive: 'text-destructive',
  }[tone];

  return (
    <div className={cn('rounded-lg border bg-card p-4 shadow-xs sm:p-5', className)}>
      <div className="flex items-start justify-between gap-3">
        <p className="text-sm font-medium text-muted-foreground">{label}</p>
        {Icon ? <Icon className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden /> : null}
      </div>
      <p className={cn('tabular mt-2 text-2xl font-semibold tracking-tight', toneClass)}>{value}</p>
      {hint ? <p className="mt-1 text-xs text-muted-foreground">{hint}</p> : null}
    </div>
  );
}
