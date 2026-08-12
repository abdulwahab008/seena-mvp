import Link from 'next/link';

const LINKS = [
  { href: '/onboarding', label: 'Setup' },
  { href: '/campuses', label: 'Campuses' },
  { href: '/branding', label: 'Branding' },
  { href: '/sessions', label: 'Sessions' },
  { href: '/staff', label: 'Staff' },
  { href: '/staff/directory', label: 'Staff Directory' },
  { href: '/staff/qualifications', label: 'Qualifications' },
  { href: '/leave', label: 'Leave' },
  { href: '/admissions/enquiries', label: 'Admissions' },
  { href: '/admissions/applications', label: 'Applications' },
  { href: '/admissions/checklist', label: 'Document Checklist' },
  { href: '/admissions/test-sittings', label: 'Test Sittings' },
  { href: '/admissions/interviews', label: 'Interviews' },
  { href: '/admissions/reminders', label: 'Reminders' },
  { href: '/academic-setup/curriculum', label: 'Curriculum' },
  { href: '/academic-setup/rooms', label: 'Rooms' },
  { href: '/academic-setup/bell-templates', label: 'Bell Templates' },
  { href: '/academic-setup/timetable', label: 'Timetable' },
  { href: '/academic-setup/timetable-export', label: 'Timetable Export' },
  { href: '/academic-setup/substitutions', label: 'Substitutions' },
  { href: '/my-timetable', label: 'My Timetable' },
  { href: '/academic-setup/teachable-subjects', label: 'Teachable Subjects' },
  { href: '/academic-setup/competency', label: 'Teacher Competency' },
  { href: '/academic-setup/rollover', label: 'Session Rollover' },
  { href: '/academic-setup/attendance-policy', label: 'Attendance Policy' },
  { href: '/attendance/register', label: 'Attendance Register' },
  { href: '/attendance/corrections', label: 'Attendance Corrections' },
  { href: '/attendance/monthly-summary', label: 'Monthly Attendance Summary' },
  { href: '/attendance/absentee-notifications', label: 'Absentee Notifications' },
  { href: '/attendance/unmarked', label: 'Unmarked Attendance' },
  { href: '/students', label: 'Students' },
  { href: '/students/import', label: 'Student Import' },
  { href: '/students/promotion', label: 'Student Promotion' },
  { href: '/students/recycle-bin', label: 'Recycle Bin' },
  { href: '/homework', label: 'Homework' },
  { href: '/fees/heads', label: 'Fee Heads' },
  { href: '/fees/structure', label: 'Fee Structure' },
  { href: '/fees/concessions', label: 'Concessions' },
  { href: '/fees/challans', label: 'Challans' },
  { href: '/fees/counter', label: 'Cash Counter' },
  { href: '/fees/reports', label: 'Collection Reports' },
  { href: '/fees/late-fee-rules', label: 'Late Fee Rules' },
  { href: '/fees/sibling-discounts', label: 'Sibling Discounts' },
  { href: '/certificates/templates', label: 'Certificate Templates' },
  { href: '/audit-export', label: 'Audit Export' },
];

export function AppNav() {
  return (
    <nav className="mb-6 flex gap-4 border-b pb-3 text-sm">
      {LINKS.map((l) => (
        <Link key={l.href} href={l.href} className="text-muted-foreground hover:text-foreground">
          {l.label}
        </Link>
      ))}
    </nav>
  );
}
