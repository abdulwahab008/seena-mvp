import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { formatDatePk, todayPk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { NewTestForm } from './new-test-form';
import { CLASS_TEST_ROLES } from './schemas';

export const dynamic = 'force-dynamic';

export default async function ClassTestsPage({ searchParams }: { searchParams: Promise<{ section?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !CLASS_TEST_ROLES.includes(actor.role)) notFound();
  const { section } = await searchParams;
  const supabase = await supabaseServer();
  let query = supabase
    .from('class_test')
    .select('id, title, test_date, total_marks, results_sent_at, subject:subject_id(name_en), section:section_id(name, class_level:class_level_id(name_en)), class_test_mark(marks, absent)')
    .order('test_date', { ascending: false })
    .limit(200);
  if (section) query = query.eq('section_id', section);
  const [{ data: tests, error }, { data: sectionRows }, { data: subjects }] = await Promise.all([
    query,
    supabase.from('class_section').select('id, name, class_level:class_level_id(name_en, ordinal)').eq('is_active', true),
    supabase.from('subject').select('id, name_en').order('name_en'),
  ]);
  const sections = (sectionRows ?? [])
    .map((s) => ({ id: s.id, label: `${one(s.class_level)?.name_en ?? ''} ${s.name}`.trim(), sort: one(s.class_level)?.ordinal ?? 0 }))
    .sort((a, b) => a.sort - b.sort || a.label.localeCompare(b.label));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Class tests</h1>
        <p className="text-sm text-muted-foreground">Weekly and monthly tests for one class: set the test, enter marks, and text the results to parents.</p>
      </div>
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base">Add a test</CardTitle>
        </CardHeader>
        <CardContent>
          <NewTestForm sections={sections.map(({ id, label }) => ({ id, label }))} subjects={subjects ?? []} today={todayPk()} />
        </CardContent>
      </Card>
      <form method="get" className="flex items-end gap-2 text-sm">
        <select name="section" defaultValue={section ?? ''} aria-label="Filter by class" className="h-9 rounded-md border bg-background px-2">
          <option value="">All classes</option>
          {sections.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>
      {error ? (
        <p className="text-sm text-destructive">Could not load tests. Try again.</p>
      ) : (tests ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No class tests yet.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">#</TableHead>
              <TableHead>Class</TableHead>
              <TableHead>Subject</TableHead>
              <TableHead>Test</TableHead>
              <TableHead>Date</TableHead>
              <TableHead className="text-right">Total</TableHead>
              <TableHead className="text-right">Students</TableHead>
              <TableHead className="text-right">Average</TableHead>
              <TableHead>Results</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(tests ?? []).map((t, i) => {
              const sec = one(t.section);
              const marked = (t.class_test_mark ?? []).filter((m) => !m.absent && m.marks !== null);
              const avg = marked.length ? marked.reduce((s, m) => s + Number(m.marks), 0) / marked.length : null;
              return (
                <TableRow key={t.id} data-testid="class-test-row">
                  <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                  <TableCell>{`${one(sec?.class_level)?.name_en ?? ''} ${sec?.name ?? ''}`.trim()}</TableCell>
                  <TableCell>{one(t.subject)?.name_en ?? ''}</TableCell>
                  <TableCell>
                    <Link href={`/exams/class-tests/${t.id}`} className="font-medium text-primary hover:underline">
                      {t.title}
                    </Link>
                  </TableCell>
                  <TableCell className="whitespace-nowrap">{formatDatePk(t.test_date)}</TableCell>
                  <TableCell className="tabular text-right">{Number(t.total_marks)}</TableCell>
                  <TableCell className="tabular text-right">{(t.class_test_mark ?? []).length}</TableCell>
                  <TableCell className="tabular text-right">{avg === null ? '' : avg.toFixed(1)}</TableCell>
                  <TableCell>{t.results_sent_at ? <Badge variant="success">Sent</Badge> : <Badge variant="outline">Not sent</Badge>}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
