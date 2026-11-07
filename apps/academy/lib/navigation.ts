import {
  Award,
  BadgeCheck,
  Banknote,
  BookOpen,
  Landmark,
  Boxes,
  Building2,
  Bus,
  BedDouble,
  CalendarClock,
  ClipboardCheck,
  FileBarChart,
  GraduationCap,
  LayoutDashboard,
  Library,
  ListChecks,
  Receipt,
  ScrollText,
  ShieldCheck,
  UserCog,
  Users,
  Wallet,
  MessageSquare,
  type LucideIcon,
} from 'lucide-react';
import { FEE_STAFF_ROLES, FRONT_DESK_ROLES } from '@/lib/auth/fee-access';

export type NavItem = {
  href: string;
  label: string;
  /** Extra path prefixes that should also light this item up. */
  match?: string[];
  /**
   * FR-A17 feature code. The item is hidden when the tenant's resolved flag
   * set says the module is off — presentation only; the route and its RPCs
   * are gated in the database.
   */
  feature?: string;
  /**
   * Roles that see the item. Presentation only, like `feature`: the route and the data behind it
   * are gated by the route's own guard and by row-level security. An item with no `roles` is for
   * everyone; a session whose role is unknown sees none of the items that have them.
   */
  roles?: readonly string[];
};

export type NavSection = {
  id: string;
  label: string;
  icon: LucideIcon;
  items: NavItem[];
};

// Who sees which modules in the sidebar. Presentation only (see NavItem.roles): every page and
// its data are still gated by the route and by row-level security. The point is that a teacher,
// a librarian or a nurse is not shown dozens of screens that would only refuse them.
const LEADERSHIP = ['super_admin', 'owner', 'principal', 'vice_principal'] as const;
const OWNERS = ['super_admin', 'owner'] as const;
const SCHOOL_ADMIN = ['super_admin', 'owner', 'principal'] as const;
const FRONT_OFFICE = [...LEADERSHIP, 'admissions_officer', 'receptionist'] as const;
const HR_ROLES = [...LEADERSHIP, 'hr_manager'] as const;
const SCHOOL_ADMIN_HR = [...SCHOOL_ADMIN, 'hr_manager'] as const;
const PAYROLL_ROLES = ['super_admin', 'owner', 'principal', 'hr_manager', 'accountant'] as const;
const FINANCE_ROLES = ['super_admin', 'owner', 'principal', 'accountant'] as const;
const ACADEMIC_LEADS = [...LEADERSHIP, 'head_of_department', 'hr_manager'] as const;

/** The fee staff, plus the admissions officer for the two fees pages their admissions work uses. */
const FEES_ADMISSIONS_ROLES = [...FEE_STAFF_ROLES, 'admissions_officer'] as const;

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
    items: [
      { href: '/dashboard', label: 'Dashboard' },
      { href: '/dashboard/owner', label: 'Owner KPIs', roles: OWNERS },
      { href: '/dashboard/today', label: 'Today', roles: LEADERSHIP },
      { href: '/dashboard/collection', label: 'Billing vs Collection', roles: FINANCE_ROLES },
    ],
  },
  // Top level rather than inside Settings: a school that has not finished
  // setting up needs this to be the most findable thing in the product, and a
  // collapsed section hides it exactly when it matters most.
  {
    id: 'setup',
    label: 'Setup',
    icon: ListChecks,
    items: [{ href: '/onboarding', label: 'Setup', roles: SCHOOL_ADMIN }],
  },
  {
    id: 'admissions',
    label: 'Admissions',
    icon: ClipboardCheck,
    items: [
      { href: '/front-desk', label: 'Front Desk', roles: FRONT_OFFICE },
      { href: '/admissions/walk-in', label: 'Walk-in Desk', roles: FRONT_OFFICE },
      { href: '/admissions/enquiries', label: 'Enquiries', roles: FRONT_OFFICE },
      { href: '/admissions/applications', label: 'Applications', roles: FRONT_OFFICE },
      { href: '/admissions/checklist', label: 'Document Checklist', roles: FRONT_OFFICE },
      { href: '/admissions/test-sittings', label: 'Test Sittings', roles: FRONT_OFFICE },
      { href: '/admissions/interviews', label: 'Interviews', roles: FRONT_OFFICE },
      { href: '/admissions/reminders', label: 'Reminders', roles: FRONT_OFFICE },
      { href: '/admissions/guardian-claims', label: 'Parent Claims', roles: FRONT_OFFICE },
    ],
  },
  {
    id: 'students',
    label: 'Students',
    icon: Users,
    items: [
      { href: '/students', label: 'All Students' },
      { href: '/students/alumni', label: 'Alumni' },
      { href: '/students/transfers', label: 'Campus Transfers', roles: FRONT_OFFICE },
      { href: '/students/withdrawals', label: 'Withdrawal Register', roles: FRONT_OFFICE },
      { href: '/students/vaccinations', label: 'Vaccinations', roles: [...LEADERSHIP, 'nurse'] },
      { href: '/students/merge', label: 'Merge Duplicates', roles: ['super_admin', 'owner', 'principal'] },
      { href: '/students/import', label: 'Bulk Import', roles: FRONT_OFFICE },
      { href: '/students/promotion', label: 'Promotion', roles: [...LEADERSHIP, 'exam_controller'] },
      { href: '/students/recycle-bin', label: 'Recycle Bin', roles: FRONT_OFFICE },
      { href: '/consent', label: 'Consent' },
      { href: '/houses', label: 'Houses' },
      { href: '/ptm', label: 'Parent-Teacher Meetings' },
    ],
  },
  {
    id: 'staff',
    label: 'Staff',
    icon: UserCog,
    items: [
      { href: '/staff', label: 'All Staff', roles: HR_ROLES },
      { href: '/staff/directory', label: 'Directory' },
      { href: '/staff/departments', label: 'Departments', roles: HR_ROLES },
      { href: '/staff/qualifications', label: 'Qualifications', roles: HR_ROLES },
      { href: '/staff/compliance', label: 'Compliance', roles: HR_ROLES },
      { href: '/staff/biometric', label: 'Biometric Attendance', roles: HR_ROLES },
      { href: '/staff/discipline', label: 'Disciplinary', roles: HR_ROLES },
      { href: '/staff/exits', label: 'Exits', roles: HR_ROLES },
      { href: '/staff/certificates', label: 'Certificates', roles: HR_ROLES },
      { href: '/id-cards', label: 'ID Cards', roles: [...FRONT_OFFICE, 'hr_manager'] },
      { href: '/staff/workload', label: 'Teacher Workload', roles: [...ACADEMIC_LEADS, 'exam_controller'] },
      { href: '/staff/recruitment', label: 'Recruitment', roles: HR_ROLES },
      { href: '/staff/appraisals', label: 'Appraisals', roles: HR_ROLES },
      { href: '/staff/training', label: 'Training & CPD', roles: SCHOOL_ADMIN_HR },
      { href: '/staff/grievances', label: 'Grievances' },
      { href: '/staff/remarks', label: 'Remarks Moderation', roles: [...ACADEMIC_LEADS, 'exam_controller'] },
      { href: '/staff/tickets', label: 'Support Tickets' },
      { href: '/leave', label: 'Leave' },
      { href: '/academic-setup/competency', label: 'Teacher Competency', roles: ACADEMIC_LEADS },
      { href: '/academic-setup/teachable-subjects', label: 'Teachable Subjects', roles: ACADEMIC_LEADS },
    ],
  },
  {
    id: 'payroll',
    label: 'Payroll',
    icon: Banknote,
    items: [
      { href: '/payroll/runs', label: 'Payroll Runs', roles: PAYROLL_ROLES },
      { href: '/payroll/components', label: 'Salary Components', roles: PAYROLL_ROLES },
      { href: '/payroll/structures', label: 'Salary Structures', roles: PAYROLL_ROLES },
      { href: '/payroll/loans', label: 'Staff Loans', roles: PAYROLL_ROLES },
      { href: '/payroll/tax-slabs', label: 'Tax Slabs', roles: PAYROLL_ROLES },
      { href: '/payroll/statutory', label: 'Statutory Report', roles: PAYROLL_ROLES },
    ],
  },
  {
    id: 'academics',
    label: 'Academics',
    icon: BookOpen,
    items: [
      { href: '/academic-setup/subjects', label: 'Subjects' },
      { href: '/academic-setup/classes-sections', label: 'Classes & Sections' },
      { href: '/academic-setup/curriculum', label: 'Curriculum' },
      { href: '/academic-setup/syllabus', label: 'Syllabus' },
      { href: '/academic-setup/rooms', label: 'Rooms' },
      { href: '/homework', label: 'Homework', feature: 'module.homework' },
      { href: '/quizzes', label: 'Online Quizzes' },
      { href: '/hifz', label: 'Hifz & Quran' },
      { href: '/downloads', label: 'Download Centre' },
      { href: '/lesson-plans', label: 'Lesson Plans' },
      { href: '/syllabus-coverage', label: 'Syllabus Coverage' },
      { href: '/syllabus-variance', label: 'Syllabus Variance' },
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
      { href: '/academic-setup/free-periods', label: 'Free Teachers & Rooms' },
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
      { href: '/attendance/periods', label: 'Period Attendance' },
      { href: '/attendance/corrections', label: 'Corrections' },
      { href: '/attendance/unmarked', label: 'Unmarked Registers' },
      { href: '/attendance/monthly-summary', label: 'Monthly Summary' },
      { href: '/attendance/shortage', label: 'Shortage Warnings' },
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
      { href: '/exams/paper-scope', label: 'Syllabus Paper Scope' },
      { href: '/exams/remarks', label: 'Teacher Remarks' },
      { href: '/exams/moderation', label: 'Moderation' },
      { href: '/exams/approvals', label: 'Mark Approval' },
      { href: '/exams/unlocks', label: 'Break-Glass Unlocks' },
      { href: '/exams/datesheet', label: 'Datesheet' },
      { href: '/exams/invigilation', label: 'Invigilation' },
      { href: '/exams/seating', label: 'Seating Plans' },
      { href: '/exams/papers', label: 'Question Papers' },
    ],
  },
  {
    id: 'results',
    label: 'Results',
    icon: FileBarChart,
    items: [
      { href: '/exams/grading', label: 'Grading Schemes' },
      { href: '/exams/results', label: 'Term Results & Positions' },
      { href: '/exams/tabulation', label: 'Tabulation, Merit & Failure Lists' },
      { href: '/exams/behaviour', label: 'Behaviour Ratings' },
      { href: '/exams/rechecks', label: 'Re-checks' },
      { href: '/exams/external-results', label: 'Board Results' },
      { href: '/exams/annual', label: 'Annual Results' },
      { href: '/exams/promotion', label: 'Promotion Decisions' },
      { href: '/exams/analytics', label: 'Subject Analytics' },
      { href: '/exams/mastery', label: 'Topic Mastery' },
      { href: '/exams/packets', label: 'Report Card Packets' },
      { href: '/exams/resits', label: 'Re-sits & Improvements' },
      { href: '/exams/board-forms', label: 'Board Exam Forms' },
      { href: '/transcripts', label: 'Transcripts' },
    ],
  },
  {
    id: 'fees',
    label: 'Fees',
    icon: Wallet,
    items: [
      { href: '/fees/heads', label: 'Fee Heads', roles: FEE_STAFF_ROLES },
      { href: '/fees/structure', label: 'Fee Structure', roles: FEE_STAFF_ROLES },
      { href: '/fees/challans', label: 'Challans', roles: FEE_STAFF_ROLES },
      { href: '/fees/counter', label: 'Cash Counter', roles: [...FEE_STAFF_ROLES, ...FRONT_DESK_ROLES] },
      { href: '/fees/defaulters', label: 'Defaulters', roles: FEE_STAFF_ROLES },
      { href: '/fees/reminders', label: 'Reminders', roles: FEE_STAFF_ROLES },
      { href: '/fees/settlements', label: 'Withdrawal Settlements', roles: FEE_STAFF_ROLES },
      { href: '/fees/no-dues', label: 'Deposits and No-Dues', roles: FEE_STAFF_ROLES },
      { href: '/fees/gateway-settlements', label: 'Gateway Settlements', roles: FEE_STAFF_ROLES },
      { href: '/fees/attendance-concessions', label: 'Attendance Concessions', roles: FEE_STAFF_ROLES },
      { href: '/fees/concessions', label: 'Concessions', roles: FEES_ADMISSIONS_ROLES },
      { href: '/fees/sibling-discounts', label: 'Sibling Discounts', roles: FEES_ADMISSIONS_ROLES },
      { href: '/fees/late-fee-rules', label: 'Late Fee Rules', roles: FEE_STAFF_ROLES },
      { href: '/fees/gateways', label: 'Online Payments', roles: FEE_STAFF_ROLES },
      { href: '/fees/bank-statements', label: 'Bank Statements', roles: FEE_STAFF_ROLES },
      { href: '/fees/reports', label: 'Collection Reports', roles: FEE_STAFF_ROLES },
    ],
  },
  {
    id: 'accounts',
    label: 'Accounts',
    icon: Landmark,
    items: [
      { href: '/accounts', label: 'General Ledger', roles: ['super_admin', 'owner', 'principal', 'accountant'] },
    ],
  },
  {
    id: 'expenses',
    label: 'Expenses',
    icon: Receipt,
    items: [
      { href: '/expenses/vouchers', label: 'Vouchers', feature: 'module.expenses', roles: FINANCE_ROLES },
      { href: '/expenses/approvals', label: 'Approvals', feature: 'module.expenses', roles: FINANCE_ROLES },
      { href: '/expenses/petty-cash', label: 'Petty Cash', feature: 'module.expenses', roles: FINANCE_ROLES },
      { href: '/expenses/chart', label: 'Chart & Budgets', feature: 'module.expenses', roles: FINANCE_ROLES },
    ],
  },
  {
    id: 'transport',
    label: 'Transport',
    icon: Bus,
    items: [
      { href: '/transport/routes', label: 'Routes & Fares', feature: 'module.transport', roles: [...LEADERSHIP, 'transport_manager', 'accountant'] },
      { href: '/transport/fleet', label: 'Fleet & Documents', feature: 'module.transport', roles: [...LEADERSHIP, 'transport_manager', 'accountant'] },
      { href: '/transport/crew', label: 'Drivers & Crew', feature: 'module.transport', roles: [...LEADERSHIP, 'transport_manager', 'accountant'] },
      { href: '/transport/assignments', label: 'Assignments', feature: 'module.transport', roles: [...LEADERSHIP, 'transport_manager', 'accountant'] },
      { href: '/transport/allocations', label: 'Student Allocation', feature: 'module.transport', roles: [...LEADERSHIP, 'transport_manager', 'accountant'] },
      { href: '/transport/boarding', label: 'Boarding', feature: 'module.transport', roles: [...LEADERSHIP, 'transport_manager', 'accountant'] },
      { href: '/transport/live', label: 'Live Tracking', feature: 'module.transport', roles: [...LEADERSHIP, 'transport_manager', 'accountant'] },
    ],
  },
  {
    id: 'hostel',
    label: 'Hostel',
    icon: BedDouble,
    items: [
      { href: '/hostel', label: 'Blocks & Beds', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/hostel/allocations', label: 'Bed Allocation', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/hostel/gate-passes', label: 'Gate Passes', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/hostel/visitors', label: 'Visitors', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/hostel/mess', label: 'Mess Menu & Mess-off', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/hostel/fees', label: 'Hostel & Mess Fees', roles: [...LEADERSHIP, 'accountant'] },
    ],
  },
  {
    id: 'inventory',
    label: 'Stores & Assets',
    icon: Boxes,
    items: [
      { href: '/inventory', label: 'Stores and Stock', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/inventory/sales', label: 'Counter Sales', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/inventory/sales-report', label: 'Sales Report', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/assets', label: 'Asset Register', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/assets/custody', label: 'Asset Custody', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/assets/maintenance', label: 'Maintenance', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/purchasing', label: 'Requisitions', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/purchasing/orders', label: 'Purchase Orders', roles: [...LEADERSHIP, 'accountant'] },
    ],
  },
  {
    id: 'certificates',
    label: 'Certificates',
    icon: Award,
    items: [
      { href: '/certificates/issue', label: 'Issue Transfer Certificate', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/issue/character', label: 'Issue Character Certificate', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/issue/leaving', label: 'Issue Leaving Certificate', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/requests', label: 'Bonafide Requests', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/verification', label: 'Verification Activity', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/register', label: 'Register', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/templates', label: 'Templates', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/serials', label: 'Serial Numbers', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/signing', label: 'Signing Identities', roles: [...FRONT_OFFICE, 'exam_controller'] },
      { href: '/certificates/board-export', label: 'Board Registration Export', roles: [...FRONT_OFFICE, 'exam_controller'] },
    ],
  },
  {
    id: 'compliance',
    label: 'Compliance',
    icon: ShieldCheck,
    items: [
      { href: '/audit-export', label: 'Audit Trail Export', roles: SCHOOL_ADMIN },
      { href: '/compliance/census', label: 'Census & EMIS Returns', roles: SCHOOL_ADMIN },
      { href: '/impersonation', label: 'Support Access', roles: SCHOOL_ADMIN },
    ],
  },
  {
    id: 'communication',
    label: 'Communication',
    icon: MessageSquare,
    items: [
      { href: '/communication/outbox', label: 'Message Outbox', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/sms-gateway', label: 'SMS Gateway', roles: OWNERS },
      { href: '/communication/scheduled', label: 'Scheduled Sends', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/triggers', label: 'Trigger Rules', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/receipts', label: 'Delivery Receipts', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/wallet', label: 'Credit & Wallet', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/opt-outs', label: 'Opt-Outs & Suppression', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/circulars', label: 'Circulars', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/calendar', label: 'Events Calendar', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/segments', label: 'Audience Segments', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/templates', label: 'Template Library', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/fallback-chains', label: 'Fallback Chains', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
      { href: '/communication/whatsapp', label: 'WhatsApp Compliance', roles: [...LEADERSHIP, 'admissions_officer', 'receptionist'] },
    ],
  },
  {
    id: 'library',
    label: 'Library',
    icon: Library,
    items: [
      { href: '/library/titles', label: 'Catalogue', roles: [...LEADERSHIP, 'librarian'] },
      { href: '/library/copies', label: 'Copies', roles: [...LEADERSHIP, 'librarian'] },
      { href: '/library/circulation', label: 'Circulation Desk', roles: [...LEADERSHIP, 'librarian'] },
      { href: '/library/reservations', label: 'Reservations', roles: [...LEADERSHIP, 'librarian'] },
      { href: '/library/fines', label: 'Fines', roles: [...LEADERSHIP, 'librarian'] },
      { href: '/library/stock-audit', label: 'Stock Audit', roles: [...LEADERSHIP, 'librarian'] },
      { href: '/library/write-offs', label: 'Write-offs', roles: [...LEADERSHIP, 'librarian'] },
      { href: '/library/policies', label: 'Borrowing Policy', roles: [...LEADERSHIP, 'librarian'] },
    ],
  },
  {
    id: 'settings',
    label: 'Settings',
    icon: Building2,
    items: [
      { href: '/campuses', label: 'Campuses', roles: SCHOOL_ADMIN },
      { href: '/sessions', label: 'Academic Sessions', roles: SCHOOL_ADMIN },
      { href: '/branding', label: 'Branding', roles: SCHOOL_ADMIN },
      { href: '/users', label: 'User Accounts', roles: SCHOOL_ADMIN },
      { href: '/roles', label: 'Roles', roles: SCHOOL_ADMIN },
      { href: '/feature-flags', label: 'Modules', roles: SCHOOL_ADMIN },
      { href: '/settings/data-export', label: 'Export School Data', roles: SCHOOL_ADMIN },
      { href: '/settings/retention', label: 'Data Retention', roles: SCHOOL_ADMIN },
    ],
  },
  {
    id: 'reports',
    label: 'Reports',
    icon: FileBarChart,
    items: [
      { href: '/reports/exports', label: 'Excel Exports', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/reports/audit', label: 'Export Audit', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/reports/digests', label: 'Scheduled Digests', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/reports/year-on-year', label: 'Year on Year', roles: [...LEADERSHIP, 'accountant'] },
      { href: '/reports/builder', label: 'Report Builder', roles: [...LEADERSHIP, 'accountant'] },
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

/**
 * Drops the items the role may not see, and any section left with nothing in it. Presentation
 * only: see NavItem.roles.
 */
export function navSectionsForRole(sections: NavSection[], role: string | undefined): NavSection[] {
  return sections
    .map((section) => ({
      ...section,
      items: section.items.filter((item) => !item.roles || (role !== undefined && item.roles.includes(role))),
    }))
    .filter((section) => section.items.length > 0);
}
