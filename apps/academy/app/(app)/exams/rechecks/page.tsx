import { supabaseServer } from '@/lib/supabase/server';
import { loadTermSection, TermSectionForm } from '@/lib/exams/term-section';
import { formatPkr } from '@/lib/challan/html';
import { formatDatePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { DecideRecheck, RecheckRequestForm } from './recheck-forms';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function RechecksPage({ searchParams }: { searchParams: Promise<{ term?: string }> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const picked = await loadTermSection(supabase, sp);
  const termId = picked.termId;

  const [{ data: rechecks }, { data: results }] = termId
    ? await Promise.all([
        supabase
          .from('result_recheck')
          .select('id, fee_paisa, reason, marks_before, marks_after, status, outcome_note, requested_at, subject(name_en), enrolment(student(name_en, gr_number))')
          .eq('exam_term_id', termId)
          .order('requested_at', { ascending: false }),
        supabase.from('subject_result').select('enrolment_id, subject_id, subject(name_en), enrolment(student(name_en, gr_number))').eq('exam_term_id', termId),
      ])
    : [{ data: [] }, { data: [] }];

  const students = [...new Map((results ?? []).map((r) => {
    const s = one(one(r.enrolment)?.student ?? null);
    return [r.enrolment_id, `${s?.name_en ?? ''} (${s?.gr_number ?? ''})`] as const;
  })).entries()].map(([id, label]) => ({ id, label })).sort((a, b) => a.label.localeCompare(b.label));
  const subjectsByStudent: Record<string, { id: string; label: string }[]> = {};
  for (const r of results ?? []) (subjectsByStudent[r.enrolment_id] ??= []).push({ id: r.subject_id, label: one(r.subject)?.name_en ?? '' });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Re-checks</h1>
        <p className="text-sm text-muted-foreground">
          A parent asks for a paper to be re-checked: record the request and its fee, then the outcome. If the marks change, correct them through Break-Glass Unlocks so the mark audit stays in one place; this register keeps the before and after.
        </p>
      </div>
      <TermSectionForm {...picked} withSection={false} />
      {termId && students.length > 0 && <RecheckRequestForm termId={termId} students={students} subjectsByStudent={subjectsByStudent} />}
      {(rechecks ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No re-checks for this term.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Student</TableHead>
              <TableHead>Subject</TableHead>
              <TableHead>Requested</TableHead>
              <TableHead className="text-right">Fee</TableHead>
              <TableHead className="text-right">Marks</TableHead>
              <TableHead>Outcome</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(rechecks ?? []).map((r) => {
              const s = one(one(r.enrolment)?.student ?? null);
              return (
                <TableRow key={r.id} data-testid="recheck-row">
                  <TableCell>
                    {s?.name_en} <span className="text-xs text-muted-foreground">{s?.gr_number}</span>
                    <span className="block text-xs text-muted-foreground">{r.reason}</span>
                  </TableCell>
                  <TableCell>{one(r.subject)?.name_en}</TableCell>
                  <TableCell>{formatDatePk(r.requested_at.slice(0, 10))}</TableCell>
                  <TableCell className="text-right">{formatPkr(r.fee_paisa)}</TableCell>
                  <TableCell className="text-right">
                    {Number(r.marks_before)}
                    {r.status === 'changed' ? ` → ${Number(r.marks_after)}` : ''}
                  </TableCell>
                  <TableCell>
                    {r.status === 'requested' ? (
                      <DecideRecheck id={r.id} />
                    ) : (
                      <>
                        <Badge variant={r.status === 'changed' ? 'warning' : 'outline'}>{r.status === 'changed' ? 'Marks changed' : 'No change'}</Badge>
                        {r.outcome_note && <span className="block text-xs text-muted-foreground">{r.outcome_note}</span>}
                      </>
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
