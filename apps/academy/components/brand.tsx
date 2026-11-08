import { cn } from '@/lib/utils';

export const BRAND_NAME = 'Classora';

/** The Classora mark: four class blocks, one in gold. Same artwork as app/icon.svg. */
export function BrandMark({ className, plain = false }: { className?: string; plain?: boolean }) {
  return (
    <svg viewBox="0 0 64 64" className={cn('h-8 w-8 shrink-0', className)} aria-hidden>
      {!plain && <rect width="64" height="64" rx="16" fill="#2E44B8" />}
      <rect x="14" y="14" width="16" height="16" rx="4" fill="#fff" />
      <rect x="34" y="14" width="16" height="16" rx="4" fill="#fff" opacity=".55" />
      <rect x="14" y="34" width="16" height="16" rx="4" fill="#fff" opacity=".55" />
      <rect x="34" y="34" width="16" height="16" rx="4" fill="#FBBF24" />
    </svg>
  );
}
