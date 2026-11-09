import Link from 'next/link';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

const SECTIONS = [
  {
    title: 'Student reports',
    items: [
      { href: '/students/reports/strength', label: 'Student strength report' },
      { href: '/students/admission-register', label: 'Admission register' },
      { href: '/students/withdrawals', label: 'Withdrawal register' },
      { href: '/students/alumni', label: 'Alumni register' },
      { href: '/fees/concessions', label: 'Free and discounted students' },
      { href: '/fees/sibling-discounts', label: 'Sibling discount report' },
      { href: '/ptm', label: 'PTM sheet' },
      { href: '/students/coaching', label: 'Extra coaching strength report' },
      { href: '/students/vaccinations', label: 'Vaccinations due' },
      { href: '/id-cards', label: 'Student ID cards' },
    ],
  },
  { title: 'Student forms', items: [{ href: '/students/reports/admission-form', label: 'Admission form' }] },
];

export default function StudentReportsPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Student reports</h1>
        <p className="text-sm text-muted-foreground">Every student report and printable form in one place.</p>
      </div>
      {SECTIONS.map((s) => (
        <Table key={s.title}>
          <TableHeader>
            <TableRow>
              <TableHead className="w-12">#</TableHead>
              <TableHead>{s.title}</TableHead>
              <TableHead className="w-24 text-right" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {s.items.map((r, i) => (
              <TableRow key={r.href} data-testid="report-row">
                <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                <TableCell>{r.label}</TableCell>
                <TableCell className="text-right">
                  <Link href={r.href} className="text-sm font-medium text-primary hover:underline">
                    View
                  </Link>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      ))}
    </div>
  );
}
