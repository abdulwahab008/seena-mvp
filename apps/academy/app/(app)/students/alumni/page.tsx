import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { one } from '@/lib/hr/current-role';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const STATUS_LABEL: Record<string, string> = { graduated: 'Graduated', left: 'Left' };

export default async function AlumniPage({ searchParams }: { searchParams: Promise<{ q?: string; status?: string }> }) {
  const { q = '', status = 'graduated' } = await searchParams;
  const supabase = await supabaseServer();

  let query = supabase
    .from('student')
    .select('id, name_en, gr_number, father_name_en, status, enrolment(created_at, class_level:class_level_id(name_en), session:session_id(name))')
    .is('deleted_at', null)
    .order('name_en')
    .limit(300);
  query = status === 'all' ? query.in('status', ['graduated', 'left']) : query.eq('status', status === 'left' ? 'left' : 'graduated');
  if (q.trim()) query = query.or(`name_en.ilike.%${q.trim().replace(/[%,()]/g, '')}%,gr_number.ilike.%${q.trim().replace(/[%,()]/g, '')}%`);
  const { data: students } = await query;

  const rows = (students ?? []).map((s) => {
    const last = [...(s.enrolment ?? [])].sort((a, b) => b.created_at.localeCompare(a.created_at))[0];
    return { ...s, lastClass: one(last?.class_level)?.name_en ?? '—', lastSession: one(last?.session)?.name ?? '—' };
  });

  return (
    <>
      <PageHeader title="Alumni" description="Students who have graduated or left, with the last class and session they were in." />
      <form method="get" className="mb-4 flex flex-wrap items-end gap-2">
        <Input name="q" defaultValue={q} placeholder="Name or GR number" className="max-w-xs" aria-label="Search alumni" />
        <select name="status" defaultValue={status} className="h-10 rounded-md border border-input bg-background px-3 text-sm" aria-label="Status">
          <option value="graduated">Graduated</option>
          <option value="left">Left</option>
          <option value="all">Both</option>
        </select>
        <Button type="submit" variant="outline">
          Search
        </Button>
      </form>
      {rows.length === 0 ? (
        <EmptyState title="No alumni found" description="Students appear here once their status is graduated or left." />
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Name</TableHead>
              <TableHead>GR</TableHead>
              <TableHead>Father</TableHead>
              <TableHead>Last class</TableHead>
              <TableHead>Session</TableHead>
              <TableHead>Status</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((s) => (
              <TableRow key={s.id} data-testid="alumni-row">
                <TableCell>
                  <Link href={`/students/${s.id}`} className="font-medium text-primary underline">
                    {s.name_en}
                  </Link>
                </TableCell>
                <TableCell>{s.gr_number}</TableCell>
                <TableCell>{s.father_name_en ?? '—'}</TableCell>
                <TableCell>{s.lastClass}</TableCell>
                <TableCell>{s.lastSession}</TableCell>
                <TableCell>{STATUS_LABEL[s.status] ?? s.status}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </>
  );
}
