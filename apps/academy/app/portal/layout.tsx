import Link from 'next/link';
import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';

const PORTAL_LINKS = [
  { href: '/portal/homework', label: 'Homework' },
  { href: '/portal/timetable', label: 'Timetable' },
  { href: '/portal/consent', label: 'Consent' },
];

// The parent/guardian portal. Deliberately separate from (app)'s layout —
// that one's nav links (Campuses, Fees, Staff...) are all staff surfaces a
// parent's own RLS would mostly return empty on; this is the one guardians
// (FR-C11) actually land in.
export default async function PortalLayout({ children }: { children: React.ReactNode }) {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

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
