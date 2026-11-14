'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { cn } from '@/lib/utils';
import { NAV_SECTIONS, activeTabHref, findActiveItem, navSectionsForRole } from '@/lib/navigation';
import { visibleNavSections, type FeatureSet } from '@/lib/features';

/** The tab bar for a sidebar item that groups several pages, shown above whichever of them is open. */
export function SectionTabs({ role, features }: { role?: string; features?: FeatureSet }) {
  const pathname = usePathname();
  const forRole = navSectionsForRole(NAV_SECTIONS, role);
  const item = findActiveItem(pathname, features ? visibleNavSections(forRole, features) : forRole);
  if (!item?.tabs || item.tabs.length < 2) return null;
  const current = activeTabHref(item, pathname);
  if (!current) return null;

  return (
    <nav aria-label={`${item.label} pages`} className="mb-6 flex gap-1 overflow-x-auto border-b print:hidden">
      {item.tabs.map((t) => {
        const active = t.href === current;
        return (
          <Link
            key={t.href}
            href={t.href}
            aria-current={active ? 'page' : undefined}
            className={cn(
              '-mb-px whitespace-nowrap border-b-2 px-3 py-2 text-sm font-medium transition-colors',
              active ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground hover:text-foreground',
            )}
          >
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}
