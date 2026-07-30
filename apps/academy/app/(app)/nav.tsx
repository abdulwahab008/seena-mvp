import Link from 'next/link';

const LINKS = [
  { href: '/campuses', label: 'Campuses' },
  { href: '/sessions', label: 'Sessions' },
  { href: '/staff', label: 'Staff' },
  { href: '/leave', label: 'Leave' },
  { href: '/admissions/enquiries', label: 'Admissions' },
  { href: '/admissions/applications', label: 'Applications' },
  { href: '/academic-setup/curriculum', label: 'Curriculum' },
  { href: '/students', label: 'Students' },
  { href: '/fees/heads', label: 'Fee Heads' },
  { href: '/fees/structure', label: 'Fee Structure' },
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
