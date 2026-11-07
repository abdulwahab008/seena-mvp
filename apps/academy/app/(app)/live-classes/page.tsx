import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { formatDateTimePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { CancelLiveClass, LiveClassForm } from './live-class-forms';

export const dynamic = 'force-dynamic';

export default async function LiveClassesPage() {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student'].includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const [{ data: classes }, { data: sections }, { data: subjects }] = await Promise.all([
    supabase
      .from('live_class')
      .select('id, title, starts_at, duration_min, meeting_url, cancelled_at, section:section_id(name, class_level:class_level_id(name_en)), subject:subject_id(name_en), live_class_attendance(student_id)')
      .eq('campus_id', campus.id)
      .order('starts_at', { ascending: false })
      .limit(100),
    supabase.from('class_section').select('id, name, class_level:class_level_id(name_en, ordinal)').eq('campus_id', campus.id).eq('is_active', true),
    supabase.from('subject').select('id, name_en').order('name_en'),
  ]);
  const sectionOptions = (sections ?? [])
    .map((s) => ({ id: s.id, label: `${one(s.class_level)?.name_en ?? ''} ${s.name}`.trim(), ordinal: one(s.class_level)?.ordinal ?? 0 }))
    .sort((a, b) => a.ordinal - b.ordinal || a.label.localeCompare(b.label));

  return (
    <>
      <PageHeader title="Live classes" description="Schedule an online class with a Zoom, Meet or Teams link. Students join from their portal, which marks them present." />
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        {(classes ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No live classes yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Class</TableHead>
                <TableHead>Section</TableHead>
                <TableHead>Starts</TableHead>
                <TableHead className="text-right">Joined</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {(classes ?? []).map((c) => {
                const section = one(c.section);
                return (
                  <TableRow key={c.id} data-testid="live-class-row">
                    <TableCell>
                      {c.title}
                      {one(c.subject)?.name_en ? <span className="block text-xs text-muted-foreground">{one(c.subject)?.name_en}</span> : null}
                    </TableCell>
                    <TableCell>
                      {one(section?.class_level ?? null)?.name_en} {section?.name}
                    </TableCell>
                    <TableCell>
                      {formatDateTimePk(c.starts_at)} · {c.duration_min} min
                    </TableCell>
                    <TableCell className="text-right">{(c.live_class_attendance ?? []).length}</TableCell>
                    <TableCell className="text-right">
                      {c.cancelled_at ? <Badge variant="outline">Cancelled</Badge> : <CancelLiveClass id={c.id} />}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
        <LiveClassForm sections={sectionOptions} subjects={(subjects ?? []).map((s) => ({ id: s.id, label: s.name_en }))} />
      </div>
    </>
  );
}
