import Link from 'next/link';
import { requireSession } from '@/lib/auth/require-session';
import { getLang } from '@/lib/i18n/server';
import { dirFor, t, type MessageKey } from '@/lib/i18n/messages';
import { LanguageToggle } from '@/components/language-toggle';

const PORTAL_LINKS: { href: string; key: MessageKey }[] = [
  { href: '/portal/attendance', key: 'nav.attendance' },
  { href: '/portal/fees', key: 'nav.fees' },
  { href: '/portal/homework', key: 'nav.homework' },
  { href: '/portal/timetable', key: 'nav.timetable' },
  { href: '/portal/results', key: 'nav.results' },
  { href: '/portal/datesheet', key: 'nav.datesheet' },
  { href: '/portal/consent', key: 'nav.consent' },
  { href: '/portal/circulars', key: 'nav.circulars' },
  { href: '/portal/calendar', key: 'nav.calendar' },
  { href: '/portal/leave', key: 'nav.leave' },
  { href: '/portal/transport', key: 'nav.transport' },
  { href: '/portal/hostel', key: 'nav.hostel' },
  { href: '/portal/remarks', key: 'nav.remarks' },
  { href: '/portal/syllabus', key: 'nav.syllabus' },
  { href: '/portal/ptm', key: 'nav.ptm' },
  { href: '/portal/tickets', key: 'nav.tickets' },
  { href: '/portal/link-child', key: 'nav.linkChild' },
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
  const lang = await getLang();

  return (
    <div className="mx-auto max-w-2xl p-4 sm:p-6" dir={dirFor(lang)} lang={lang}>
      <div className="mb-2 flex items-center justify-between gap-2">
        <h1 className="text-lg font-semibold">{t(lang, 'portal.title')}</h1>
        <LanguageToggle lang={lang} />
      </div>
      <nav className="mb-6 flex flex-wrap gap-x-4 gap-y-2 text-sm">
        {PORTAL_LINKS.map((l) => (
          <Link key={l.href} href={l.href} className="text-muted-foreground hover:text-foreground">
            {t(lang, l.key)}
          </Link>
        ))}
      </nav>
      {children}
    </div>
  );
}
