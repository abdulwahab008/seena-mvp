import Link from 'next/link';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

const SECTIONS = [
  {
    title: 'Staff reports',
    items: [
      { href: '/staff/reports/strength', label: 'Staff strength report' },
      { href: '/staff/directory', label: 'Staff directory' },
      { href: '/staff/org-chart', label: 'Org chart' },
      { href: '/staff/hr-dashboard', label: 'HR dashboard' },
      { href: '/staff/workload', label: 'Teacher workload' },
      { href: '/staff/qualifications', label: 'Qualifications' },
      { href: '/staff/compliance', label: 'CNIC and document expiries' },
      { href: '/staff/appraisals', label: 'Appraisals' },
      { href: '/staff/training', label: 'Training report' },
      { href: '/staff/exits', label: 'Staff exits' },
      { href: '/leave', label: 'Leave register' },
    ],
  },
  {
    title: 'Payroll reports',
    items: [
      { href: '/payroll/runs', label: 'Salary sheets and pay slips' },
      { href: '/payroll/loans', label: 'Loans and advances' },
      { href: '/payroll/gratuity', label: 'Gratuity' },
      { href: '/payroll/pay-scales', label: 'Pay scales' },
    ],
  },
  {
    title: 'Staff documents and cards',
    items: [
      { href: '/staff/certificates', label: 'Experience, service and NOC certificates' },
      { href: '/id-cards', label: 'Staff ID cards' },
    ],
  },
];

export default function StaffReportsPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff reports</h1>
        <p className="text-sm text-muted-foreground">Every staff and payroll report, document and card in one place.</p>
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
