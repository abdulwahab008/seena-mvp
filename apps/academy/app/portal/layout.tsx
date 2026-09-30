import Link from 'next/link';
import { requireSession } from '@/lib/auth/require-session';

const PORTAL_LINKS = [
  { href: '/portal/attendance', label: 'Attendance' },
  { href: '/portal/fees', label: 'Fees' },
  { href: '/portal/homework', label: 'Homework' },
  { href: '/portal/timetable', label: 'Timetable' },
  { href: '/portal/results', label: 'Results' },
  { href: '/portal/consent', label: 'Consent' },
  { href: '/portal/circulars', label: 'Circulars' },
  { href: '/portal/calendar', label: 'Calendar' },
  { href: '/portal/remarks', label: 'Remarks' },
  { href: '/portal/tickets', label: 'Support & Complaints' },
];

// The parent/guardian portal. Deliberately separate from (app)'s layout —
// that one's nav links (Campuses, Fees, Staff...) are all staff surfaces a
// parent's own RLS would mostly return empty on; this is the one guardians
// (FR-C11) actually land in.
export default async function PortalLayout({ children }: { children: React.ReactNode }) {
  // Guardians reach the portal through their own activation flow, which
  // creates no app_user row, so this intentionally checks only for a session
  // — the /no-school membership rule belongs to the staff app, not here.
  await requireSession();

  return (
    <div className="mx-auto max-w-2xl p-6">
      <h1 className="mb-2 text-lg font-semibold">Parent Portal</h1>
      <nav className="mb-6 flex gap-4 text-sm">
        {PORTAL_LINKS.map((l) => (
          <Link key={l.href} href={l.href} className="text-muted-foreground hover:text-foreground">
            {l.label}
          </Link>
        ))}
      </nav>
      {children}
    </div>
  );
}
