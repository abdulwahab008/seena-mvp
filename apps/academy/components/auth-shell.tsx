import Link from 'next/link';
import { GraduationCap } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';

/**
 * The centred-card frame every unauthenticated page shares (/login, /sign-up,
 * /forgot-password, /reset-password, /no-school). Kept as one component so the
 * auth flow reads as a single surface rather than four near-identical pages
 * that drift apart.
 */
export function AuthShell({
  title,
  description,
  children,
  footer,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
}) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-muted/40 p-4">
      <div className="w-full max-w-sm space-y-4">
        <Link href="/" className="flex items-center justify-center gap-2 text-foreground">
          <GraduationCap className="h-6 w-6 text-primary" aria-hidden />
          <span className="text-lg font-semibold tracking-tight">Seena Academy</span>
        </Link>
        <Card>
          <CardHeader>
            <CardTitle>{title}</CardTitle>
            {description ? <CardDescription>{description}</CardDescription> : null}
          </CardHeader>
          <CardContent className="space-y-4">{children}</CardContent>
        </Card>
        {footer ? <div className="text-center text-sm text-muted-foreground">{footer}</div> : null}
      </div>
    </div>
  );
}
