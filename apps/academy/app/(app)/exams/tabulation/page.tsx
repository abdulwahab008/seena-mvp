import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { loadTermSection, TermSectionForm } from '@/lib/exams/term-section';
import { cn } from '@/lib/utils';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { PrintButton, SendResultsButton } from './tabulation-actions';

export const dynamic = 'force-dynamic';

const VIEWS = [
  { id: 'all', label: 'Tabulation register' },
  { id: 'merit', label: 'Merit list' },
  { id: 'failures', label: 'Failure list' },
] as const;
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const marks = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(2));

export default async function TabulationPage({ searchParams }: { searchParams: Promise<{ section?: string; term?: string; view?: string }> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const picked = await loadTermSection(supabase, sp);
  const { sectionId, termId } = picked;
  const view = VIEWS.some((v) => v.id === sp.view) ? sp.view! : 'all';

  const [{ data: results }, { data: positions }, { data: enrolments }] =
    sectionId && termId
      ? await Promise.all([
          supabase.from('subject_result').select('enrolment_id, subject_id, obtained, max_marks, grade_label, is_pass, report_symbol, subject(name_en, code)').eq('exam_term_id', termId).eq('section_id', sectionId),
          supabase.from('result_position').select('enrolment_id, total_obtained, total_max, rank_in_section, exclusion_reason').eq('exam_term_id', termId).eq('section_id', sectionId),
          supabase.from('enrolment').select('id, roll_no, student(name_en, gr_number)').eq('section_id', sectionId),
        ])
      : [{ data: [] }, { data: [] }, { data: [] }];

  const subjects = [...new Map((results ?? []).map((r) => [r.subject_id, one(r.subject)])).entries()]
    .map(([id, s]) => ({ id, name: s?.code || s?.name_en || '' }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const position = new Map((positions ?? []).map((p) => [p.enrolment_id, p]));
  const rows = (enrolments ?? [])
    .filter((e) => position.has(e.id))
    .map((e) => {
      const p = position.get(e.id)!;
      const mine = (results ?? []).filter((r) => r.enrolment_id === e.id);
      const s = one(e.student);
      return {
        id: e.id,
        rollNo: e.roll_no,
        name: s?.name_en ?? '',
        gr: s?.gr_number ?? '',
        bySubject: new Map(mine.map((r) => [r.subject_id, r])),
        failed: mine.filter((r) => r.is_pass === false).length,
        total: Number(p.total_obtained),
        max: p.total_max,
        pct: p.total_max > 0 ? (Number(p.total_obtained) * 100) / p.total_max : 0,
        rank: p.rank_in_section,
        excluded: p.exclusion_reason,
      };
    });
  const shown =
    view === 'merit'
      ? rows.filter((r) => r.rank !== null).sort((a, b) => a.rank! - b.rank!)
      : view === 'failures'
        ? rows.filter((r) => r.failed > 0)
        : rows.sort((a, b) => (a.rollNo ?? 9999) - (b.rollNo ?? 9999) || a.name.localeCompare(b.name));
  const sectionLabel = picked.sectionOptions.find((s) => s.id === sectionId)?.label ?? '';
  const termLabel = picked.termOptions.find((t) => t.id === termId)?.label ?? '';

  return (
    <div className="space-y-4">
      <div className="print:hidden">
        <h1 className="text-2xl font-semibold">Tabulation register</h1>
        <p className="text-sm text-muted-foreground">
          Every student&apos;s marks in every subject for one term, with totals and positions. The merit list orders by position; the failure list shows anyone who failed a subject. Send each family the result by SMS from here.
        </p>
      </div>
      <div className="flex flex-wrap items-end justify-between gap-3 print:hidden">
        <TermSectionForm {...picked} hidden={{ view }} />
        <div className="flex gap-2">
          <PrintButton />
          {sectionId && termId && rows.length > 0 && <SendResultsButton termId={termId} sectionId={sectionId} />}
        </div>
      </div>
      <nav className="flex gap-2 print:hidden" aria-label="Result lists">
        {VIEWS.map((v) => (
          <Link
            key={v.id}
            href={`/exams/tabulation?section=${sectionId ?? ''}&term=${termId ?? ''}&view=${v.id}`}
            className={cn('rounded-full border px-3 py-1 text-sm', v.id === view ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted')}
          >
            {v.label}
          </Link>
        ))}
      </nav>
      <h2 className="font-medium">
        {VIEWS.find((v) => v.id === view)!.label} · {sectionLabel} · {termLabel}
      </h2>

      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="tabulation-empty">
          No results have been computed for this section and term yet. Results appear once the section&apos;s papers are approved.
        </p>
      ) : shown.length === 0 ? (
        <p className="text-sm text-muted-foreground">Nobody in this list.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Roll</TableHead>
              <TableHead>Student</TableHead>
              {subjects.map((s) => (
                <TableHead key={s.id} className="text-center">
                  {s.name}
                </TableHead>
              ))}
              <TableHead className="text-right">Total</TableHead>
              <TableHead className="text-right">%</TableHead>
              <TableHead className="text-right">Position</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {shown.map((r) => (
              <TableRow key={r.id} data-testid="tabulation-row">
                <TableCell>{r.rollNo ?? ''}</TableCell>
                <TableCell>
                  {r.name} <span className="text-xs text-muted-foreground">{r.gr}</span>
                </TableCell>
                {subjects.map((s) => {
                  const x = r.bySubject.get(s.id);
                  return (
                    <TableCell key={s.id} className={cn('text-center', x?.is_pass === false && 'font-medium text-destructive')}>
                      {x ? (x.report_symbol ?? `${marks(Number(x.obtained))}/${x.max_marks}`) : '–'}
                      {x?.grade_label ? <span className="block text-xs text-muted-foreground">{x.grade_label}</span> : null}
                    </TableCell>
                  );
                })}
                <TableCell className="text-right">
                  {marks(r.total)}/{r.max}
                </TableCell>
                <TableCell className="text-right">{r.pct.toFixed(1)}</TableCell>
                <TableCell className="text-right">{r.rank ?? (r.excluded === 'withheld' ? 'Withheld' : '–')}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
