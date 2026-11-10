import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { formatDatePk } from '@/lib/dates';
import { PrintButton } from '@/components/print-button';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const CATEGORIES = { behaviour: 'Behaviour', bullying: 'Bullying', attendance: 'Attendance', uniform: 'Uniform', academic_dishonesty: 'Cheating', property_damage: 'Property damage', other: 'Other' } as const;
const SEVERITY = { minor: 'success', moderate: 'warning', serious: 'destructive' } as const;
const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;

export default async function DisciplineRegisterPage({ searchParams }: { searchParams: Promise<{ severity?: string; category?: string; q?: string }> }) {
  const f = await searchParams;
  const supabase = await supabaseServer();
  let query = supabase
    .from('student_incident')
    .select('id, occurred_on, category, severity, description, action_taken, parent_informed, student:student_id!inner(id, name_en, gr_number)')
    .order('occurred_on', { ascending: false })
    .limit(300);
  if (f.severity && f.severity in SEVERITY) query = query.eq('severity', f.severity);
  if (f.category && f.category in CATEGORIES) query = query.eq('category', f.category);
  if (f.q?.trim()) query = query.ilike('student.name_en', `%${f.q.trim().replace(/[\\%_]/g, (c) => `\\${c}`)}%`);
  const { data: incidents, error } = await query;
  const select = 'h-9 rounded-md border bg-background px-2';

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Discipline register</h1>
          <p className="text-sm text-muted-foreground">Every incident recorded against a student. Record a new one from the student&apos;s profile.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      <form method="get" className="flex flex-wrap items-end gap-2 rounded-lg border p-4 text-sm print:hidden">
        <select name="severity" defaultValue={f.severity ?? ''} aria-label="Severity" className={select}>
          <option value="">All severities</option>
          {Object.keys(SEVERITY).map((s) => (
            <option key={s} value={s}>
              {s.charAt(0).toUpperCase() + s.slice(1)}
            </option>
          ))}
        </select>
        <select name="category" defaultValue={f.category ?? ''} aria-label="Category" className={select}>
          <option value="">All categories</option>
          {Object.entries(CATEGORIES).map(([k, label]) => (
            <option key={k} value={k}>
              {label}
            </option>
          ))}
        </select>
        <input name="q" defaultValue={f.q ?? ''} placeholder="Student name" aria-label="Student name" className="h-9 min-w-48 flex-1 rounded-md border bg-background px-3" />
        <Button type="submit" size="sm">
          Search
        </Button>
        {Object.values(f).some(Boolean) && (
          <Link href="/students/discipline" className="h-9 px-2 leading-9 text-muted-foreground underline">
            Clear
          </Link>
        )}
        <p className="w-full text-muted-foreground">
          There are <span className="tabular font-medium text-foreground">{incidents?.length ?? 0}</span> incidents.
        </p>
      </form>
      {error ? (
        <p className="text-sm text-destructive">Could not load incidents. Try again.</p>
      ) : (incidents ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No disciplinary incidents recorded.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">#</TableHead>
              <TableHead>Date</TableHead>
              <TableHead>Student</TableHead>
              <TableHead>Category</TableHead>
              <TableHead>Severity</TableHead>
              <TableHead>What happened</TableHead>
              <TableHead>Action taken</TableHead>
              <TableHead>Parent told</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(incidents ?? []).map((r, i) => {
              const s = one(r.student);
              return (
                <TableRow key={r.id} data-testid="incident-row">
                  <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                  <TableCell className="whitespace-nowrap">{formatDatePk(r.occurred_on)}</TableCell>
                  <TableCell>
                    {s && (
                      <Link href={`/students/${s.id}`} className="font-medium hover:underline">
                        {s.name_en} <span className="text-muted-foreground">({s.gr_number})</span>
                      </Link>
                    )}
                  </TableCell>
                  <TableCell>{CATEGORIES[r.category as keyof typeof CATEGORIES] ?? r.category}</TableCell>
                  <TableCell>
                    <Badge variant={SEVERITY[r.severity as keyof typeof SEVERITY] ?? 'outline'}>{r.severity}</Badge>
                  </TableCell>
                  <TableCell className="max-w-xs">{r.description}</TableCell>
                  <TableCell className="max-w-xs">{r.action_taken ?? ''}</TableCell>
                  <TableCell>{r.parent_informed ? 'Yes' : 'No'}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
