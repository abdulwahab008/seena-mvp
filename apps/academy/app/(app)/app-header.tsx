'use client';

import * as React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ChevronRight, LogOut, Menu, User, X } from 'lucide-react';
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { breadcrumbsFor } from '@/lib/navigation';
import type { FeatureSet } from '@/lib/features';
import { SidebarContent } from './sidebar';

function Breadcrumbs() {
  const pathname = usePathname();
  const crumbs = breadcrumbsFor(pathname);
  if (crumbs.length === 0) return null;

  return (
    <nav aria-label="Breadcrumb" className="hidden min-w-0 sm:block">
      <ol className="flex items-center gap-1.5 text-sm text-muted-foreground">
        {crumbs.map((c, i) => {
          const last = i === crumbs.length - 1;
          return (
            <li key={`${c.label}-${i}`} className="flex min-w-0 items-center gap-1.5">
              {i > 0 ? <ChevronRight className="h-3.5 w-3.5 shrink-0 opacity-60" aria-hidden /> : null}
              {last ? (
                <span className="truncate font-medium text-foreground" aria-current="page">
                  {c.label}
                </span>
              ) : (
                <span className="truncate">{c.label}</span>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}

function UserMenu({ email, role }: { email: string; role: string }) {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const initials = email.slice(0, 2).toUpperCase();

  return (
    <div className="relative" ref={ref}>
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-haspopup="menu"
        className="flex items-center gap-2 rounded-full p-1 pr-2 text-sm transition-colors hover:bg-muted"
        data-testid="user-menu-trigger"
      >
        <span className="flex h-8 w-8 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-foreground">
          {initials}
        </span>
        <span className="hidden max-w-[10rem] truncate text-muted-foreground md:inline">{email}</span>
      </button>

      {open ? (
        <div
          role="menu"
          className="absolute right-0 z-50 mt-2 w-64 animate-fade-in overflow-hidden rounded-lg border bg-popover text-popover-foreground shadow-lg"
          data-testid="user-menu"
        >
          <div className="border-b px-4 py-3">
            <p className="truncate text-sm font-medium">{email}</p>
            <p className="mt-0.5 text-xs capitalize text-muted-foreground">
              {role.replace(/_/g, ' ')}
            </p>
          </div>
          <div className="p-1">
            <Link
              href="/account"
              role="menuitem"
              onClick={() => setOpen(false)}
              className="flex items-center gap-2.5 rounded-md px-3 py-2 text-sm hover:bg-muted"
            >
              <User className="h-4 w-4 text-muted-foreground" aria-hidden />
              Your profile
            </Link>
            <form action="/api/auth/sign-out" method="post" className="contents">
              <button
                type="submit"
                role="menuitem"
                className="flex w-full items-center gap-2.5 rounded-md px-3 py-2 text-left text-sm text-destructive hover:bg-destructive-muted"
                data-testid="sign-out"
              >
                <LogOut className="h-4 w-4" aria-hidden />
                Sign out
              </button>
            </form>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export function AppHeader({
  email,
  role,
  schoolName,
  features,
  /** FR-A16: the impersonation banner is fixed to the top, so the header sticks below it. */
  impersonating = false,
}: {
  email: string;
  role: string;
  schoolName: string;
  features?: FeatureSet;
  impersonating?: boolean;
}) {
  const [drawer, setDrawer] = React.useState(false);
  const pathname = usePathname();

  // A drawer that survives navigation hides the page the user just asked for.
  React.useEffect(() => setDrawer(false), [pathname]);

  React.useEffect(() => {
    document.body.style.overflow = drawer ? 'hidden' : '';
    return () => {
      document.body.style.overflow = '';
    };
  }, [drawer]);

  return (
    <>
      <header
        className={cn(
          'sticky z-30 flex h-14 items-center gap-3 border-b bg-surface/90 px-4 backdrop-blur supports-[backdrop-filter]:bg-surface/75 sm:px-6',
          impersonating ? 'top-11' : 'top-0',
        )}
      >
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="lg:hidden"
          onClick={() => setDrawer(true)}
          aria-label="Open navigation"
          data-testid="open-nav"
        >
          <Menu className="h-5 w-5" />
        </Button>

        <Breadcrumbs />

        <div className="ml-auto flex items-center gap-1">
          <UserMenu email={email} role={role} />
        </div>
      </header>

      {drawer ? (
        <div className="fixed inset-0 z-50 lg:hidden" role="dialog" aria-modal="true" aria-label="Navigation">
          <button
            type="button"
            className="absolute inset-0 animate-fade-in bg-foreground/40 backdrop-blur-[1px]"
            onClick={() => setDrawer(false)}
            aria-label="Close navigation"
          />
          <div className={cn('absolute inset-y-0 left-0 w-72 animate-slide-in-left shadow-lg')}>
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className="absolute right-2 top-3 z-10 text-sidebar-foreground hover:bg-sidebar-accent hover:text-white"
              onClick={() => setDrawer(false)}
              aria-label="Close navigation"
            >
              <X className="h-5 w-5" />
            </Button>
            <SidebarContent
              schoolName={schoolName}
              features={features}
              onNavigate={() => setDrawer(false)}
              reserveCloseSpace
            />
          </div>
        </div>
      ) : null}
    </>
  );
}
