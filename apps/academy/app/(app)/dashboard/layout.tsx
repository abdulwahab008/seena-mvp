import type { ReactNode } from 'react';
import { getCurrentActor } from '@/lib/hr/current-role';
import { FINANCE_ROLES, LEADERSHIP, OWNERS } from '@/lib/navigation';
import { DashboardTabs } from './dashboard-tabs';

const TABS: { href: string; label: string; roles?: readonly string[] }[] = [
  { href: '/dashboard', label: 'Overview' },
  { href: '/dashboard/today', label: 'Today', roles: LEADERSHIP },
  { href: '/dashboard/owner', label: 'School KPIs', roles: OWNERS },
  { href: '/dashboard/collection', label: 'Billing vs Collection', roles: FINANCE_ROLES },
];

export default async function DashboardLayout({ children }: { children: ReactNode }) {
  const actor = await getCurrentActor();
  const tabs = TABS.filter((t) => !t.roles || (actor && t.roles.includes(actor.role)));
  return (
    <div className="space-y-6">
      {tabs.length > 1 && <DashboardTabs tabs={tabs.map(({ href, label }) => ({ href, label }))} />}
      {children}
    </div>
  );
}
