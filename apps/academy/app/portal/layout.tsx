import Link from 'next/link';
import { redirect } from 'next/navigation';
import { requireSession } from '@/lib/auth/require-session';
import { isNoSchoolRedirect, portalRedirectFor } from '@/lib/auth/portal-access';
import { supabaseServer } from '@/lib/supabase/server';
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
  { href: '/portal/certificates', key: 'nav.certificates' },
  { href: '/portal/link-child', key: 'nav.linkChild' },
];

// The parent/guardian portal. Deliberately separate from (app)'s layout —
// that one's nav links (Campuses, Fees, Staff...) are all staff surfaces a
// parent's own RLS would mostly return empty on; this is the one guardians
// (FR-C11) actually land in.
export default async function PortalLayout({ children }: { children: React.ReactNode }) {
  // Guardians reach the portal through their own activation flow, which
  // creates no app_user row, so the /no-school membership rule of the staff app
  // does not apply here.
  const user = await requireSession();

  // Only a guardian may render any portal page. The pages below pick "this
  // guardian's children" with an unfiltered enrolment query and trust row-level
  // security to have narrowed it; for staff that policy is campus-wide, so a staff
  // or student session that typed a portal URL used to see every child in the
  // campus (and a real fee balance) here. See lib/auth/portal-access.ts.
  const supabase = await supabaseServer();
  const { data: verified } = await supabase.auth.getClaims();
  const target = portalRedirectFor(verified?.claims.app_role);
  if (target) {
    if (isNoSchoolRedirect(target)) {
      // A guardian whose token predates being linked to a child carries the role
      // 'none' until it refreshes; they still own a guardian row and belong here.
      const { data: guardian } = await supabase
        .from('guardian')
        .select('id')
        .eq('auth_user_id', user.id)
        .maybeSingle();
      if (!guardian) redirect(target);
    } else {
      redirect(target);
    }
  }

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
