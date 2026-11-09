import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { allRows } from '@/lib/supabase/all-rows';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;
const localPhone = (e164: string) => (e164.startsWith('+92') ? `0${e164.slice(3)}` : e164);

export default async function FamilyListPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const q = (await searchParams).q?.trim() ?? '';
  const supabase = await supabaseServer();
  const { data: families, error } = await allRows((from, to) =>
    supabase
      .from('family_group')
      .select('id, family_no, father_cnic, guardian:primary_guardian_id(name_en, phone_e164), student(id, name_en, gr_number, status, deleted_at)')
      .order('family_no')
      .range(from, to),
  );

  const digits = q.replace(/\D/g, '');
  const rows = families
    .map((f) => ({ ...f, guardian: one(f.guardian), students: (f.student ?? []).filter((s) => !s.deleted_at) }))
    .filter((f) => f.students.length > 0)
    .filter(
      (f) =>
        !q ||
        String(f.family_no) === q ||
        (digits.length >= 5 && ((f.father_cnic ?? '').includes(digits) || (f.guardian?.phone_e164 ?? '').includes(digits.slice(-10)))) ||
        (f.guardian?.name_en ?? '').toLowerCase().includes(q.toLowerCase()) ||
        f.students.some((s) => s.name_en.toLowerCase().includes(q.toLowerCase())),
    );

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Family list</h1>
        <p className="text-sm text-muted-foreground">Brothers and sisters grouped by family, linked through the father&apos;s CNIC.</p>
      </div>
      <form method="get" className="flex flex-wrap items-end gap-2 rounded-lg border p-4 text-sm print:hidden">
        <input name="q" defaultValue={q} placeholder="Family number, CNIC, phone, parent or student name" aria-label="Search families" className="h-9 min-w-72 flex-1 rounded-md border bg-background px-3" />
        <Button type="submit" size="sm">
          Search
        </Button>
        {q && (
          <Link href="/students/families" className="h-9 px-2 leading-9 text-muted-foreground underline">
            Clear
          </Link>
        )}
        <p className="w-full text-muted-foreground">
          There are <span className="tabular font-medium text-foreground">{rows.length}</span> families
          {q ? ' matching' : ''}.
        </p>
      </form>
      {error ? (
        <p className="text-sm text-destructive">Could not load families. Try again.</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {q ? 'No families match this search.' : "No families yet. Students are grouped into a family when their father's CNIC is recorded."}
        </p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">#</TableHead>
              <TableHead>Family no.</TableHead>
              <TableHead>Family name</TableHead>
              <TableHead>CNIC</TableHead>
              <TableHead>Mobile</TableHead>
              <TableHead>Students</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((f, i) => (
              <TableRow key={f.id} data-testid="family-row">
                <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                <TableCell className="tabular font-mono">{f.family_no}</TableCell>
                <TableCell className="font-medium">{f.guardian?.name_en ?? ''}</TableCell>
                <TableCell className="tabular">{f.father_cnic ?? ''}</TableCell>
                <TableCell className="tabular">{f.guardian?.phone_e164 ? localPhone(f.guardian.phone_e164) : ''}</TableCell>
                <TableCell>
                  <ul className="space-y-0.5">
                    {f.students.map((s) => (
                      <li key={s.id}>
                        <Link href={`/students/${s.id}`} className="hover:underline">
                          {s.name_en}
                        </Link>{' '}
                        <span className="text-muted-foreground">({s.gr_number})</span>
                      </li>
                    ))}
                  </ul>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
