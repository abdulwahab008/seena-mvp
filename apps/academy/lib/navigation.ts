import {
  Award,
  BadgeCheck,
  BookOpen,
  Building2,
  CalendarClock,
  ClipboardCheck,
  FileBarChart,
  GraduationCap,
  LayoutDashboard,
  Receipt,
  ScrollText,
  ShieldCheck,
  UserCog,
  Users,
  Wallet,
  type LucideIcon,
} from 'lucide-react';

export type NavItem = {
  href: string;
  label: string;
  /** Extra path prefixes that should also light this item up. */
  match?: string[];
};

export type NavSection = {
  id: string;
  label: string;
  icon: LucideIcon;
  items: NavItem[];
};

/**
 * The app's information architecture. Sections mirror how a school is actually
 * run (admissions -> students -> academics -> attendance -> exams -> money),
 * not the order the features happened to be built in.
 *
 * Every entry here points at a route that exists. Nothing aspirational.
 */
export const NAV_SECTIONS: NavSection[] = [
  {
    id: 'overview',
    label: 'Overview',
    icon: LayoutDashboard,
    items: [{ href: '/dashboard', label: 'Dashboard' }],
  },
  {
    id: 'admissions',
    label: 'Admissions',
    icon: ClipboardCheck,
    items: [
      { href: '/admissions/enquiries', label: 'Enquiries' },
      { href: '/admissions/applications', label: 'Applications' },
      { href: '/admissions/checklist', label: 'Document Checklist' },
      { href: '/admissions/test-sittings', label: 'Test Sittings' },
      { href: '/admissions/interviews', label: 'Interviews' },
      { href: '/admissions/reminders', label: 'Reminders' },
    ],
  },
  {
    id: 'students',
    label: 'Students',
    icon: Users,
    items: [
      { href: '/students', label: 'All Students' },
      { href: '/students/import', label: 'Bulk Import' },
      { href: '/students/promotion', label: 'Promotion' },
      { href: '/students/recycle-bin', label: 'Recycle Bin' },
      { href: '/consent', label: 'Consent' },
    ],
  },
  {
    id: 'staff',
    label: 'Staff',
    icon: UserCog,
    items: [
      { href: '/staff', label: 'All Staff' },
      { href: '/staff/directory', label: 'Directory' },
      { href: '/staff/qualifications', label: 'Qualifications' },
      { href: '/leave', label: 'Leave' },
      { href: '/academic-setup/competency', label: 'Teacher Competency' },
      { href: '/academic-setup/teachable-subjects', label: 'Teachable Subjects' },
    ],
  },
  {
    id: 'academics',
    label: 'Academics',
    icon: BookOpen,
    items: [
      { href: '/academic-setup/curriculum', label: 'Curriculum' },
      { href: '/academic-setup/rooms', label: 'Rooms' },
      { href: '/homework', label: 'Homework' },
      { href: '/academic-setup/rollover', label: 'Session Rollover' },
    ],
  },
  {
    id: 'timetable',
    label: 'Timetable',
    icon: CalendarClock,
    items: [
      { href: '/academic-setup/timetable', label: 'Timetable' },
      { href: '/academic-setup/bell-templates', label: 'Bell Templates' },
      { href: '/academic-setup/substitutions', label: 'Substitutions' },
      { href: '/academic-setup/timetable-export', label: 'Print & Export' },
      { href: '/my-timetable', label: 'My Timetable' },
    ],
  },
  {
    id: 'attendance',
    label: 'Attendance',
    icon: BadgeCheck,
    items: [
      { href: '/attendance/register', label: 'Daily Register' },
      { href: '/attendance/corrections', label: 'Corrections' },
      { href: '/attendance/unmarked', label: 'Unmarked Registers' },
      { href: '/attendance/monthly-summary', label: 'Monthly Summary' },
      { href: '/attendance/absentee-notifications', label: 'Absentee Alerts' },
      { href: '/academic-setup/attendance-policy', label: 'Attendance Policy' },
    ],
  },
  {
    id: 'exams',
    label: 'Examinations',
    icon: GraduationCap,
    items: [
      { href: '/exams/terms', label: 'Exam Terms' },
      { href: '/exams/subjects', label: 'Subjects & Components' },
      { href: '/exams/marks', label: 'Mark Entry' },
      { href: '/exams/approvals', label: 'Mark Approval' },
      { href: '/exams/unlocks', label: 'Break-Glass Unlocks' },
    ],
  },
  {
    id: 'results',
    label: 'Results',
    icon: FileBarChart,
    items: [
      { href: '/exams/grading', label: 'Grading Schemes' },
      { href: '/exams/results', label: 'Term Results & Positions' },
      { href: '/exams/annual', label: 'Annual Results' },
    ],
  },
  {
    id: 'fees',
    label: 'Fees',
    icon: Wallet,
    items: [
      { href: '/fees/heads', label: 'Fee Heads' },
      { href: '/fees/structure', label: 'Fee Structure' },
      { href: '/fees/challans', label: 'Challans' },
      { href: '/fees/counter', label: 'Cash Counter' },
      { href: '/fees/concessions', label: 'Concessions' },
      { href: '/fees/sibling-discounts', label: 'Sibling Discounts' },
      { href: '/fees/late-fee-rules', label: 'Late Fee Rules' },
      { href: '/fees/reports', label: 'Collection Reports' },
    ],
  },
  {
    id: 'expenses',
    label: 'Expenses',
    icon: Receipt,
    items: [
      { href: '/expenses/vouchers', label: 'Vouchers' },
      { href: '/expenses/approvals', label: 'Approvals' },
    ],
  },
  {
    id: 'certificates',
    label: 'Certificates',
    icon: Award,
    items: [
      { href: '/certificates/issue', label: 'Issue Transfer Certificate' },
      { href: '/certificates/issue/character', label: 'Issue Character Certificate' },
      { href: '/certificates/register', label: 'Register' },
      { href: '/certificates/templates', label: 'Templates' },
      { href: '/certificates/serials', label: 'Serial Numbers' },
      { href: '/certificates/signing', label: 'Signing Identities' },
    ],
  },
  {
    id: 'compliance',
    label: 'Compliance',
    icon: ShieldCheck,
    items: [{ href: '/audit-export', label: 'Audit Trail Export' }],
  },
  {
    id: 'settings',
    label: 'Settings',
    icon: Building2,
    items: [
      { href: '/onboarding', label: 'Setup Checklist' },
      { href: '/campuses', label: 'Campuses' },
      { href: '/sessions', label: 'Academic Sessions' },
      { href: '/branding', label: 'Branding' },
    ],
  },
];

const ALL_ITEMS = NAV_SECTIONS.flatMap((s) => s.items.map((i) => ({ ...i, section: s })));

/**
 * Longest-prefix match, so `/students/import` selects Bulk Import rather than
 * All Students. Exact match always wins.
 */
export function findActiveItem(pathname: string) {
  const exact = ALL_ITEMS.find((i) => i.href === pathname);
  if (exact) return exact;

  const prefixed = ALL_ITEMS.filter(
    (i) => pathname.startsWith(`${i.href}/`) || i.match?.some((m) => pathname.startsWith(m)),
  );
  if (prefixed.length === 0) return undefined;

  return prefixed.reduce((best, cur) => (cur.href.length > best.href.length ? cur : best));
}

export function isSectionActive(section: NavSection, pathname: string) {
  return findActiveItem(pathname)?.section.id === section.id;
}

export type Crumb = { label: string; href?: string };

export function breadcrumbsFor(pathname: string): Crumb[] {
  const active = findActiveItem(pathname);
  if (!active) return [];
  const crumbs: Crumb[] = [{ label: active.section.label }];
  // A single-item section would otherwise read "Overview / Dashboard".
  if (active.section.items.length > 1 || active.section.items[0]?.label !== active.section.label) {
    crumbs.push({ label: active.label, href: active.href });
  }
  return crumbs;
}
