import Link from 'next/link';
import { BrandMark, BRAND_NAME } from '@/components/brand';
import { cn } from '@/lib/utils';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';

/**
 * The frame every unauthenticated page shares (/login, /register-school,
 * /forgot-password, /reset-password, /no-school). Kept as one component so the
 * auth flow reads as a single surface rather than near-identical pages that
 * drift apart. `aside` adds a side panel on wide screens (the sign-in page
 * uses it to explain who signs in how); `wide` fits a two-column form.
 */
export function AuthShell({
  title,
  description,
  children,
  footer,
  aside,
  wide = false,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  aside?: React.ReactNode;
  wide?: boolean;
}) {
  const card = (
    <div className={cn('w-full space-y-4', wide ? 'max-w-xl' : 'max-w-sm')}>
      <Link href="/" className={cn('flex items-center justify-center gap-2 text-foreground', aside && 'lg:hidden')}>
        <BrandMark className="h-8 w-8" />
        <span className="text-lg font-semibold tracking-tight">{BRAND_NAME}</span>
      </Link>
      <Card>
        <CardHeader>
          <CardTitle>{title}</CardTitle>
          {description ? <CardDescription>{description}</CardDescription> : null}
        </CardHeader>
        <CardContent className="space-y-4">{children}</CardContent>
      </Card>
      {footer ? <div className="space-y-1 text-center text-sm text-muted-foreground">{footer}</div> : null}
    </div>
  );

  if (!aside) {
    return <div className="flex min-h-screen items-center justify-center bg-muted/40 p-4">{card}</div>;
  }
  return (
    <div className="grid min-h-screen bg-muted/40 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
      <aside className="hidden flex-col justify-between bg-primary p-10 text-primary-foreground lg:flex">
        <Link href="/" className="flex items-center gap-2">
          <BrandMark className="h-9 w-9" plain />
          <span className="text-xl font-semibold tracking-tight">{BRAND_NAME}</span>
        </Link>
        {aside}
        <p className="text-sm opacity-70">School management for Pakistan: fees, exams, attendance, staff and parents in one place.</p>
      </aside>
      <div className="flex items-center justify-center p-4">{card}</div>
    </div>
  );
}
