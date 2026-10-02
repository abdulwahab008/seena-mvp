import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { HomeworkRealtimeRefresher } from './homework-realtime-refresher';
import { SubmissionRealtimeRefresher } from './submission-realtime-refresher';

export default async function PortalHomeworkPage({ searchParams }: { searchParams: Promise<{ section?: string }> }) {
  const { section: sectionParam } = await searchParams;
  const supabase = await supabaseServer();

  // AC: a parent with multiple children gets a child selector. RLS
  // (enrolment_parent_read_own_children, FR-C11) already scopes this to
  // only the signed-in guardian's own active enrolments.
  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('id, section_id, student:student_id(id, name_en), class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active');

  type Child = { enrolmentId: string; studentId: string; studentName: string; sectionId: string; sectionLabel: string };
  const children: Child[] = (enrolments ?? [])
    .map((e) => {
      const student = Array.isArray(e.student) ? e.student[0] : e.student;
      const section = Array.isArray(e.class_section) ? e.class_section[0] : e.class_section;
      const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
      if (!student || !section) return null;
      return {
        enrolmentId: e.id,
        studentId: student.id,
        studentName: student.name_en,
        sectionId: e.section_id,
        sectionLabel: `${level?.name_en ?? ''} · ${section.name}`,
      };
    })
    .filter((c): c is Child => !!c);

  const selectedSectionId = sectionParam ?? children[0]?.sectionId;
  const selectedChild = children.find((c) => c.sectionId === selectedSectionId) ?? children[0];

  const { data: feedRows } = selectedSectionId
    ? await supabase
        .from('v_student_homework_feed')
        .select('id, subject_name_en, title, description, due_date, estimated_minutes, is_overdue')
        .eq('section_id', selectedSectionId)
        .order('due_date', { ascending: true })
    : { data: [] as never[] };

  const feedIds = (feedRows ?? []).map((r) => r.id).filter((v): v is string => Boolean(v));
  const { data: attachmentRows } = feedIds.length
    ? await supabase.from('homework_attachment').select('id, homework_id, original_filename').in('homework_id', feedIds).order('created_at')
    : { data: [] as never[] };
  const attachmentsFor = (id: string | null) => (attachmentRows ?? []).filter((a) => a.homework_id === id);
  const { data: mySubmissions } = selectedChild && feedIds.length
    ? await supabase.from('homework_submission').select('homework_id, status, feedback_code').eq('enrolment_id', selectedChild.enrolmentId).in('homework_id', feedIds)
    : { data: [] as never[] };
  const submissionFor = (id: string | null) => (mySubmissions ?? []).find((m) => m.homework_id === id);
  const overdue = (feedRows ?? []).filter((r) => r.is_overdue);
  const pending = (feedRows ?? []).filter((r) => !r.is_overdue);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Homework</h2>
        <p className="text-sm text-muted-foreground">FR-H04 — pending assignments for your child, due date first.</p>
      </div>

      {children.length === 0 ? (
        <p className="text-sm text-muted-foreground">No enrolled child found on this account.</p>
      ) : (
        <>
          {children.length > 1 && (
            <div className="flex flex-wrap gap-2" data-testid="homework-child-selector">
              {children.map((c) => (
                <Link
                  key={c.studentId}
                  href={`/portal/homework?section=${c.sectionId}`}
                  data-testid={`homework-child-${c.studentName}`}
                  className={`rounded-full border px-3 py-1 text-sm ${
                    c.sectionId === selectedSectionId ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'
                  }`}
                >
                  {c.studentName} ({c.sectionLabel})
                </Link>
              ))}
            </div>
          )}

          {selectedSectionId && <HomeworkRealtimeRefresher sectionId={selectedSectionId} />}
          {selectedChild && <SubmissionRealtimeRefresher enrolmentId={selectedChild.enrolmentId} />}

          {overdue.length > 0 && (
            <div className="space-y-2">
              <h3 className="text-sm font-semibold text-destructive">Overdue</h3>
              {overdue.map((h) => (
                <div key={h.id} className="rounded-lg border border-destructive p-3" data-testid={`homework-feed-${h.title}`}>
                  <p className="font-medium">
                    {h.title} <span className="text-muted-foreground">({h.subject_name_en})</span>
                  </p>
                  <p className="text-sm text-muted-foreground">Due {h.due_date}</p>
                  {submissionFor(h.id) && (
                    <span className="ml-2 rounded bg-muted px-2 py-0.5 text-xs capitalize" data-testid={`feed-status-${h.title}`}>
                      {submissionFor(h.id)?.feedback_code ? submissionFor(h.id)?.feedback_code?.replace('_', ' ') : submissionFor(h.id)?.status}
                    </span>
                  )}
                  {selectedChild && (
                    <Link href={`/portal/homework/submit?homework=${h.id}&enrolment=${selectedChild.enrolmentId}`} className="mt-1 inline-block text-sm underline" data-testid={`homework-submit-${h.title}`}>
                      Submit work
                    </Link>
                  )}
                  {attachmentsFor(h.id).length > 0 && (
                    <p className="mt-1 text-sm" data-testid="homework-feed-attachments">
                      {attachmentsFor(h.id).map((a) => (
                        <a key={a.id} href={`/api/homework-attachments/${a.id}`} className="mr-3 underline" target="_blank" rel="noreferrer">
                          {a.original_filename}
                        </a>
                      ))}
                    </p>
                  )}
                </div>
              ))}
            </div>
          )}

          <div className="space-y-2">
            <h3 className="text-sm font-semibold">Pending</h3>
            {pending.length === 0 ? (
              <p className="text-sm text-muted-foreground">Nothing pending.</p>
            ) : (
              pending.map((h) => (
                <div key={h.id} className="rounded-lg border p-3" data-testid={`homework-feed-${h.title}`}>
                  <p className="font-medium">
                    {h.title} <span className="text-muted-foreground">({h.subject_name_en})</span>
                  </p>
                  <p className="text-sm text-muted-foreground">Due {h.due_date}</p>
                  {h.description && <p className="mt-1 text-sm">{h.description}</p>}
                  {submissionFor(h.id) && (
                    <span className="ml-2 rounded bg-muted px-2 py-0.5 text-xs capitalize" data-testid={`feed-status-${h.title}`}>
                      {submissionFor(h.id)?.feedback_code ? submissionFor(h.id)?.feedback_code?.replace('_', ' ') : submissionFor(h.id)?.status}
                    </span>
                  )}
                  {selectedChild && (
                    <Link href={`/portal/homework/submit?homework=${h.id}&enrolment=${selectedChild.enrolmentId}`} className="mt-1 inline-block text-sm underline" data-testid={`homework-submit-${h.title}`}>
                      Submit work
                    </Link>
                  )}
                  {attachmentsFor(h.id).length > 0 && (
                    <p className="mt-1 text-sm" data-testid="homework-feed-attachments">
                      {attachmentsFor(h.id).map((a) => (
                        <a key={a.id} href={`/api/homework-attachments/${a.id}`} className="mr-3 underline" target="_blank" rel="noreferrer">
                          {a.original_filename}
                        </a>
                      ))}
                    </p>
                  )}
                </div>
              ))
            )}
          </div>
        </>
      )}
    </div>
  );
}
