'use client';

import * as React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ChevronDown, GraduationCap } from 'lucide-react';
import { cn } from '@/lib/utils';
import { NAV_SECTIONS, findActiveItem, type NavSection } from '@/lib/navigation';
import { visibleNavSections, type FeatureSet } from '@/lib/features';

function SectionGroup({
  section,
  pathname,
  onNavigate,
}: {
  section: NavSection;
  pathname: string;
  onNavigate?: () => void;
}) {
  const active = findActiveItem(pathname);
  const sectionActive = active?.section.id === section.id;
  const single = section.items.length === 1;

  // Open state follows the route on navigation, but a manual toggle wins until
  // the route changes again — otherwise collapsing the section you're in fights back.
  const [open, setOpen] = React.useState(sectionActive);
  const lastPath = React.useRef(pathname);
  React.useEffect(() => {
    if (lastPath.current !== pathname) {
      lastPath.current = pathname;
      setOpen(sectionActive);
    }
  }, [pathname, sectionActive]);

  const Icon = section.icon;

  if (single) {
    const item = section.items[0]!;
    const isActive = active?.href === item.href;
    return (
      <Link
        href={item.href}
        onClick={onNavigate}
        aria-current={isActive ? 'page' : undefined}
        className={cn(
          'flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
          isActive
            ? 'bg-sidebar-accent text-white'
            : 'text-sidebar-foreground hover:bg-sidebar-accent/60 hover:text-white',
        )}
      >
        <Icon className="h-4 w-4 shrink-0" aria-hidden />
        <span className="truncate">{section.label}</span>
      </Link>
    );
  }

  return (
    <div>
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className={cn(
          'flex w-full items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
          sectionActive
            ? 'text-white'
            : 'text-sidebar-foreground hover:bg-sidebar-accent/60 hover:text-white',
        )}
      >
        <Icon className="h-4 w-4 shrink-0" aria-hidden />
        <span className="flex-1 truncate text-left">{section.label}</span>
        <ChevronDown
          className={cn('h-3.5 w-3.5 shrink-0 transition-transform', open && 'rotate-180')}
          aria-hidden
        />
      </button>

      {open ? (
        <ul className="mt-0.5 space-y-0.5 border-l border-sidebar-border pl-3 ml-[1.4rem]">
          {section.items.map((item) => {
            const isActive = active?.href === item.href;
            return (
              <li key={item.href}>
                <Link
                  href={item.href}
                  onClick={onNavigate}
                  aria-current={isActive ? 'page' : undefined}
                  className={cn(
                    'block rounded-md px-3 py-1.5 text-sm transition-colors',
                    isActive
                      ? 'bg-sidebar-accent font-medium text-white'
                      : 'text-sidebar-muted hover:bg-sidebar-accent/50 hover:text-white',
                  )}
                >
                  {item.label}
                </Link>
              </li>
            );
          })}
        </ul>
      ) : null}
    </div>
  );
}

export function SidebarContent({
  schoolName,
  features,
  onNavigate,
  /** Leaves room for the drawer's close button so it never sits on the name. */
  reserveCloseSpace = false,
}: {
  schoolName: string;
  /**
   * FR-A17: the tenant's resolved flag set. Filtering happens here rather
   * than in the server layout because NavSection carries a React component
   * as its icon, which cannot cross the server/client boundary.
   */
  features?: FeatureSet;
  onNavigate?: () => void;
  reserveCloseSpace?: boolean;
}) {
  const pathname = usePathname();
  const sections = features ? visibleNavSections(NAV_SECTIONS, features) : NAV_SECTIONS;

  return (
    <div className="flex h-full flex-col bg-sidebar">
      <div
        className={cn(
          'flex items-center gap-2.5 border-b border-sidebar-border px-4 py-4',
          reserveCloseSpace && 'pr-14',
        )}
      >
        <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-sidebar-active text-white">
          <GraduationCap className="h-4 w-4" aria-hidden />
        </span>
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold leading-tight text-white">{schoolName}</p>
          <p className="text-xs leading-tight text-sidebar-muted">Seena Academy</p>
        </div>
      </div>

      <nav aria-label="Main" className="flex-1 space-y-1 overflow-y-auto px-3 py-4">
        {sections.map((section) => (
          <SectionGroup key={section.id} section={section} pathname={pathname} onNavigate={onNavigate} />
        ))}
      </nav>
    </div>
  );
}

/** Fixed rail on desktop; the mobile drawer renders the same content in a sheet. */
export function Sidebar({
  schoolName,
  features,
  /** FR-A16: the impersonation banner owns the top 2.75rem of the viewport. */
  impersonating = false,
}: {
  schoolName: string;
  features?: FeatureSet;
  impersonating?: boolean;
}) {
  return (
    <aside className="hidden w-64 shrink-0 border-r border-sidebar-border lg:block">
      <div className={cn('fixed bottom-0 left-0 w-64', impersonating ? 'top-11' : 'top-0')}>
        <SidebarContent schoolName={schoolName} features={features} />
      </div>
    </aside>
  );
}
