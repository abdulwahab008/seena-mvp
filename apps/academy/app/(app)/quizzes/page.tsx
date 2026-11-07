import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { formatDateTimePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { NewQuizForm } from './quiz-forms';

export const dynamic = 'force-dynamic';

export default async function QuizzesPage() {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student'].includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const [{ data: quizzes }, { data: sections }] = await Promise.all([
    supabase
      .from('quiz')
      .select('id, title, opens_at, closes_at, status, section:section_id(name, class_level:class_level_id(name_en)), quiz_attempt(submitted_at)')
      .eq('campus_id', campus.id)
      .order('opens_at', { ascending: false })
      .limit(100),
    supabase.from('class_section').select('id, name, class_level:class_level_id(name_en, ordinal)').eq('campus_id', campus.id).eq('is_active', true),
  ]);

  const sectionOptions = (sections ?? [])
    .map((s) => ({ id: s.id, label: `${one(s.class_level)?.name_en ?? ''} ${s.name}`.trim(), ordinal: one(s.class_level)?.ordinal ?? 0 }))
    .sort((a, b) => a.ordinal - b.ordinal || a.label.localeCompare(b.label));

  return (
    <>
      <PageHeader title="Online quizzes" description="Multiple-choice quizzes students take in their portal, marked automatically." />
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        {(quizzes ?? []).length === 0 ? (
          <EmptyState title="No quizzes yet" description="Create one with the form on this page." />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Quiz</TableHead>
                <TableHead>Class</TableHead>
                <TableHead>Open</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Submitted</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(quizzes ?? []).map((q) => {
                const sec = one(q.section);
                return (
                  <TableRow key={q.id}>
                    <TableCell>
                      <Link href={`/quizzes/${q.id}`} className="font-medium text-primary underline">
                        {q.title}
                      </Link>
                    </TableCell>
                    <TableCell>{`${one(sec?.class_level ?? null)?.name_en ?? ''} ${sec?.name ?? ''}`.trim()}</TableCell>
                    <TableCell className="text-sm">
                      {formatDateTimePk(q.opens_at)} – {formatDateTimePk(q.closes_at)}
                    </TableCell>
                    <TableCell>
                      <Badge variant={q.status === 'published' ? 'success' : 'outline'}>{q.status}</Badge>
                    </TableCell>
                    <TableCell className="text-right">{(q.quiz_attempt ?? []).filter((a) => a.submitted_at).length}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
        <NewQuizForm sections={sectionOptions.map(({ id, label }) => ({ id, label }))} />
      </div>
    </>
  );
}
