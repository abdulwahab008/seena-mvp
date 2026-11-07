import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { formatDatePk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { AddMemberForm, HalqaForm, LessonForm } from './hifz-forms';

export const dynamic = 'force-dynamic';

const ADMINS = ['super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department'];
const STREAM_LABEL: Record<string, string> = { hifz: 'Hifz', nazra: 'Nazra', qaida: 'Qaida' };

export default async function HifzPage({ searchParams }: { searchParams: Promise<{ halqa?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student'].includes(actor.role)) notFound();
  const isAdmin = ADMINS.includes(actor.role);
  const { halqa: halqaParam } = await searchParams;

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const { data: halqas } = await supabase
    .from('halqa')
    .select('id, name, stream, teacher_id, teacher:teacher_id(full_name), halqa_member(student_id, left_on)')
    .eq('campus_id', campus.id)
    .eq('is_active', true)
    .order('name');
  const list = (halqas ?? []).map((h) => ({ ...h, members: (h.halqa_member ?? []).filter((m) => !m.left_on).length }));
  const selected = list.find((h) => h.id === halqaParam) ?? list[0];

  const [{ data: progress }, { data: teachers }, { data: students }] = await Promise.all([
    selected ? supabase.rpc('halqa_progress', { p_halqa_id: selected.id }) : Promise.resolve({ data: [] }),
    isAdmin ? supabase.from('app_user').select('user_id, full_name').eq('status', 'active').not('app_role', 'in', '(parent,student)').order('full_name') : Promise.resolve({ data: [] }),
    isAdmin && selected ? supabase.from('student').select('id, name_en, gr_number').eq('campus_id', campus.id).eq('status', 'active').is('deleted_at', null).order('name_en').limit(1000) : Promise.resolve({ data: [] }),
  ]);
  const canRecord = selected && (isAdmin || selected.teacher_id === actor.userId);
  const memberIds = new Set((progress ?? []).map((p) => p.student_id));

  return (
    <>
      <PageHeader title="Hifz & Quran" description="Halqas, their students, and each day's sabaq, sabqi and manzil." />
      <div className="grid gap-6 lg:grid-cols-[16rem_1fr]">
        <div className="space-y-3">
          <nav className="space-y-1" aria-label="Halqas">
            {list.map((h) => (
              <Link
                key={h.id}
                href={`/hifz?halqa=${h.id}`}
                className={cn('block rounded-md border px-3 py-2 text-sm', h.id === selected?.id ? 'border-primary bg-primary/5' : 'hover:bg-muted')}
              >
                <span className="font-medium">{h.name}</span>
                <span className="block text-xs text-muted-foreground">
                  {STREAM_LABEL[h.stream]} · {h.members} students · {one(h.teacher)?.full_name ?? 'no teacher'}
                </span>
              </Link>
            ))}
            {list.length === 0 && <p className="text-sm text-muted-foreground">No halqas yet.</p>}
          </nav>
          {isAdmin && <HalqaForm campusId={campus.id} teachers={(teachers ?? []).map((t) => ({ id: t.user_id, name: t.full_name }))} />}
        </div>

        {selected ? (
          <div className="space-y-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base">{selected.name}: progress</CardTitle>
              </CardHeader>
              <CardContent>
                {(progress ?? []).length === 0 ? (
                  <p className="text-sm text-muted-foreground">No students in this halqa yet.</p>
                ) : (
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Student</TableHead>
                        <TableHead>Highest para</TableHead>
                        <TableHead>Lessons (30 days)</TableHead>
                        <TableHead>Mistakes (30 days)</TableHead>
                        <TableHead>Last lesson</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {(progress ?? []).map((p) => (
                        <TableRow key={p.student_id} data-testid="hifz-progress-row">
                          <TableCell className="font-medium">
                            {p.student_name} <span className="text-xs text-muted-foreground">{p.gr_number}</span>
                          </TableCell>
                          <TableCell>{p.highest_para ?? '—'}</TableCell>
                          <TableCell>{p.lessons_30d}</TableCell>
                          <TableCell>{p.mistakes_30d}</TableCell>
                          <TableCell>{p.last_lesson ? formatDatePk(p.last_lesson) : '—'}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                )}
              </CardContent>
            </Card>
            {canRecord && (progress ?? []).length > 0 && (
              <LessonForm halqaId={selected.id} students={(progress ?? []).map((p) => ({ id: p.student_id, name: p.student_name }))} />
            )}
            {isAdmin && (
              <AddMemberForm halqaId={selected.id} students={(students ?? []).filter((s) => !memberIds.has(s.id)).map((s) => ({ id: s.id, name: `${s.name_en} (${s.gr_number})` }))} />
            )}
          </div>
        ) : (
          <EmptyState title="Create a halqa to begin" description={isAdmin ? 'Use the form on the left.' : 'Ask the principal to set up halqas.'} />
        )}
      </div>
    </>
  );
}
