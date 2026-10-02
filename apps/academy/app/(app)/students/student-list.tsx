import Link from 'next/link';
import { Card, CardContent } from '@/components/ui/card';

export type StudentRow = { id: string; name_en: string; gr_number: string; status: string };

export function StudentList({ students }: { students: StudentRow[] }) {
  if (students.length === 0) {
    return <p className="text-sm text-muted-foreground">No students yet.</p>;
  }

  return (
    <div className="space-y-2">
      {students.map((s) => (
        <Link key={s.id} href={`/students/${s.id}`}>
          <Card data-testid={`student-row-${s.gr_number}`} className="transition-colors hover:bg-muted/50">
            <CardContent className="flex items-center justify-between p-4">
              <div>
                <p className="font-medium">
                  {s.name_en} <span className="text-muted-foreground">({s.gr_number})</span>
                </p>
                <p className="text-sm text-muted-foreground">{s.status}</p>
              </div>
            </CardContent>
          </Card>
        </Link>
      ))}
    </div>
  );
}
