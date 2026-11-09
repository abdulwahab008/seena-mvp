import Link from 'next/link';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export type StudentRow = {
  id: string;
  name_en: string;
  father_name_en: string | null;
  gr_number: string;
  status: string;
  className: string;
  phone: string | null;
  category: string | null;
};

function localPhone(e164: string) {
  return e164.startsWith('+92') ? `0${e164.slice(3)}` : e164;
}

export function StudentList({ students, offset }: { students: StudentRow[]; offset: number }) {
  if (students.length === 0) {
    return <p className="text-sm text-muted-foreground">No students match these filters.</p>;
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead className="w-10">#</TableHead>
          <TableHead>Name</TableHead>
          <TableHead>Father name</TableHead>
          <TableHead>WhatsApp</TableHead>
          <TableHead>Class</TableHead>
          <TableHead>Category</TableHead>
          <TableHead>GR no.</TableHead>
          <TableHead className="print:hidden">Actions</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {students.map((s, i) => (
          <TableRow key={s.id} data-testid={`student-row-${s.gr_number}`}>
            <TableCell className="tabular text-muted-foreground">{offset + i + 1}</TableCell>
            <TableCell>
              <Link href={`/students/${s.id}`} className="flex items-center gap-2 font-medium hover:underline">
                <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-muted text-xs font-semibold text-muted-foreground">
                  {s.name_en.slice(0, 1).toUpperCase()}
                </span>
                {s.name_en}
              </Link>
              {s.status !== 'active' && <span className="ml-9 text-xs text-muted-foreground">{s.status}</span>}
            </TableCell>
            <TableCell>{s.father_name_en ?? ''}</TableCell>
            <TableCell className="tabular">
              {s.phone && (
                <a href={`https://wa.me/${s.phone.replace(/\D/g, '')}`} target="_blank" rel="noreferrer" className="hover:underline">
                  {localPhone(s.phone)}
                </a>
              )}
            </TableCell>
            <TableCell>{s.className}</TableCell>
            <TableCell>{s.category && <Badge variant="outline">{s.category}</Badge>}</TableCell>
            <TableCell className="tabular font-mono">{s.gr_number}</TableCell>
            <TableCell className="print:hidden">
              <Link href={`/students/${s.id}`} className="text-sm text-primary hover:underline">
                Open
              </Link>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
