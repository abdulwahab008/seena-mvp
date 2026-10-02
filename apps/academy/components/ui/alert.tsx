import * as React from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { AlertCircle, CheckCircle2, Info, TriangleAlert } from 'lucide-react';
import { cn } from '@/lib/utils';

const alertVariants = cva('flex gap-3 rounded-lg border p-4 text-sm', {
  variants: {
    variant: {
      info: 'border-info/25 bg-info-muted text-foreground',
      success: 'border-success/25 bg-success-muted text-foreground',
      warning: 'border-warning/30 bg-warning-muted text-foreground',
      destructive: 'border-destructive/25 bg-destructive-muted text-foreground',
    },
  },
  defaultVariants: { variant: 'info' },
});

const ICONS = {
  info: Info,
  success: CheckCircle2,
  warning: TriangleAlert,
  destructive: AlertCircle,
} as const;

const ICON_TONE = {
  info: 'text-info',
  success: 'text-success',
  warning: 'text-warning',
  destructive: 'text-destructive',
} as const;

export function Alert({
  className,
  variant = 'info',
  title,
  children,
  ...props
}: React.HTMLAttributes<HTMLDivElement> &
  VariantProps<typeof alertVariants> & { title?: string }) {
  const tone = variant ?? 'info';
  const Icon = ICONS[tone];
  return (
    <div
      role={tone === 'destructive' ? 'alert' : 'status'}
      className={cn(alertVariants({ variant }), className)}
      {...props}
    >
      <Icon className={cn('mt-0.5 h-4 w-4 shrink-0', ICON_TONE[tone])} aria-hidden />
      <div className="min-w-0 space-y-1">
        {title ? <p className="font-medium leading-none">{title}</p> : null}
        {children ? <div className="text-muted-foreground [&_p]:leading-relaxed">{children}</div> : null}
      </div>
    </div>
  );
}
