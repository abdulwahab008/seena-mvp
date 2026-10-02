'use client';

import { useState } from 'react';
import Link from 'next/link';
import { toast } from 'sonner';
import { computeSubjectResults, readResultSheet } from './actions';
import type { MarkSectionOption } from '@/lib/exams/mark-query';
import type { SubjectResultRow, SubjectResultSheet } from '@/lib/exams/result-query';
import { resultDisplay } from '@/lib/exams/result-query';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

/**
 * FR-J02's board: one section's candidates, their computed subjects, and the
 * three states that are not a pass or a fail.
 *
 * The percentage is printed exactly as it is stored — two decimals, the same
 * number the grade was read off — so the grade and the percentage on this
 * screen can never disagree.
 */
type Props = {
  examTermId: string;
  termName: string;
  sections: MarkSectionOption[];
};

const pct = (row: SubjectResultRow) => (row.pct === null ? '—' : `${Number(row.pct).toFixed(2)}%`);

export function ResultBoard({ examTermId, termName, sections }: Props) {
  const [sectionId, setSectionId] = useState('');
  const [sheet, setSheet] = useState<SubjectResultSheet | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = async (id: string) => {
    if (!id) {
      setSheet(null);
      return;
    }
    setLoading(true);
    const result = await readResultSheet(examTermId, id);
    setLoading(false);
    if (result.error || !result.sheet) {
      toast.error(result.error ?? 'Could not read the results.');
      setSheet(null);
      return;
    }
    setSheet(result.sheet);
  };

  const onCompute = async () => {
    setBusy(true);
    const result = await computeSubjectResults({ examTermId, sectionId });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(`${result.rows} subject results computed.`);
    await load(sectionId);
  };

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="result-section">Section</Label>
          <select
            id="result-section"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={sectionId}
            data-testid="result-section-select"
            onChange={(e) => {
              setSectionId(e.target.value);
              setSheet(null);
            }}
          >
            <option value="">Choose a section…</option>
            {sections.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </div>
        <Button variant="outline" disabled={loading} data-testid="open-results" onClick={() => void load(sectionId)}>
          {loading ? 'Opening…' : 'Open results'}
        </Button>
      </section>

      {sheet && (
        <div className="space-y-4" data-testid="result-sheet">
          <div className="rounded-md border p-4 text-sm" data-testid="result-scale">
            {sheet.grading_scheme ? (
              <p>
                Graded on <span className="font-semibold">{sheet.board}</span> &middot; {sheet.grading_scheme.name} (v
                {sheet.grading_scheme.version}). A result keeps the version it was computed on even after a newer one
                takes effect.
              </p>
            ) : (
              <p className="text-destructive" data-testid="result-no-scale">
                No grade scale is configured for {sheet.board}. Marks can still be signed off, but nothing can be
                graded until one exists —{' '}
                <Link href="/exams/grading" className="underline">
                  configure it here
                </Link>
                .
              </p>
            )}
          </div>

          {!sheet.readiness.ready && (
            <p className="rounded-md border border-dashed p-4 text-sm text-muted-foreground" data-testid="result-not-ready">
              {sheet.readiness.locked_count} of {sheet.readiness.subject_count} papers signed off. {termName} results
              wait on <span data-testid="result-pending-subjects">{sheet.readiness.pending_subjects.join(', ')}</span>.
            </p>
          )}

          {sheet.stale_count > 0 && (
            <p className="rounded-md border border-destructive p-4 text-sm text-destructive" data-testid="result-stale-banner">
              A break-glass correction changed marks under these results. {sheet.stale_count} candidate
              {sheet.stale_count === 1 ? '' : 's'} need recomputing — what is shown below is out of date.
            </p>
          )}

          {sheet.can_compute && (
            <Button disabled={busy} data-testid="recompute-results" onClick={() => void onCompute()}>
              {busy ? 'Computing…' : 'Recompute this section'}
            </Button>
          )}

          {sheet.candidates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="result-none">
              Nothing has been computed for this section yet.
            </p>
          ) : (
            <div className="space-y-4">
              <p className="text-xs text-muted-foreground" data-testid="result-computed-at">
                Computed {sheet.computed_at ? new Date(sheet.computed_at).toLocaleString() : '—'}
              </p>
              {sheet.candidates.map((c) => (
                <div key={c.enrolment_id} className="space-y-2 rounded-md border p-4" data-testid={`result-${c.gr_number}`}>
                  <div className="flex flex-wrap items-center gap-3">
                    <h2 className="text-base font-semibold">
                      {c.roll_no !== null ? `${c.roll_no}. ` : ''}
                      {c.student_name}
                    </h2>
                    <span className="text-xs text-muted-foreground">{c.gr_number}</span>
                    {c.is_blocked && (
                      <span
                        className="rounded-full border border-destructive px-2 py-0.5 text-xs text-destructive"
                        data-testid={`result-withheld-${c.gr_number}`}
                      >
                        Result withheld — debarred in this term
                      </span>
                    )}
                  </div>

                  <table className="w-full text-sm">
                    <thead className="text-left text-muted-foreground">
                      <tr>
                        <th className="py-1">Subject</th>
                        <th className="py-1">Obtained</th>
                        <th className="py-1">Out of</th>
                        <th className="py-1">%</th>
                        <th className="py-1">Grade</th>
                        <th className="py-1">GPA</th>
                        <th className="py-1">Result</th>
                      </tr>
                    </thead>
                    <tbody>
                      {c.subjects.map((row) => (
                        <tr key={row.subject_id} data-testid={`result-${c.gr_number}-${row.subject_name}`}>
                          <td className="py-1 font-medium">
                            {row.subject_name}
                            {row.is_stale && (
                              <span className="ml-2 text-xs text-destructive" data-testid={`result-stale-${c.gr_number}-${row.subject_name}`}>
                                stale
                              </span>
                            )}
                          </td>
                          <td className="py-1">{Number(row.obtained).toFixed(2)}</td>
                          <td className="py-1">{row.max_marks}</td>
                          <td className="py-1">{pct(row)}</td>
                          <td className="py-1">{resultDisplay(row)}</td>
                          <td className="py-1">{row.gpa_point === null ? '—' : Number(row.gpa_point).toFixed(2)}</td>
                          <td className="py-1">
                            {row.is_pass === null ? (
                              <span className="text-muted-foreground">
                                {row.report_symbol === 'EX'
                                  ? 'Exempt — out of the denominator'
                                  : row.is_blocked
                                    ? 'Withheld'
                                    : '—'}
                              </span>
                            ) : row.is_pass ? (
                              <span>Pass</span>
                            ) : (
                              <span className="text-destructive">
                                Fail
                                {row.failed_components.length > 0 && (
                                  <span data-testid={`result-failed-${c.gr_number}-${row.subject_name}`}>
                                    {' '}
                                    —{' '}
                                    {row.failed_components
                                      .map((f) => `${f.component} ${Number(f.obtained)} of a pass mark of ${f.pass_marks}`)
                                      .join(', ')}
                                  </span>
                                )}
                              </span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
