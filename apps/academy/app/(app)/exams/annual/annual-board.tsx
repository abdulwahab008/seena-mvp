'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { computeAnnualResults, readAnnualSheet } from './actions';
import type { MarkSectionOption } from '@/lib/exams/mark-query';
import type { AnnualResultSheet, AnnualSubjectRow } from '@/lib/exams/annual-query';
import { annualDisplay } from '@/lib/exams/annual-query';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

/**
 * FR-J03's board: one section's weighted annual results, the term weightages
 * they came from, and the three things a report card has to be honest about —
 * a provisional figure, a stale one, and a withheld year.
 *
 * The percentage is printed exactly as it is stored. It was rounded once, at
 * the end, off exact decimals, so the number here is the number the grade was
 * read from and the two cannot disagree.
 */
type Props = {
  sessionId: string;
  sections: MarkSectionOption[];
};

const pct = (row: AnnualSubjectRow) =>
  row.weighted_pct === null ? '—' : `${Number(row.weighted_pct).toFixed(2)}%`;

export function AnnualBoard({ sessionId, sections }: Props) {
  const [sectionId, setSectionId] = useState('');
  const [sheet, setSheet] = useState<AnnualResultSheet | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = async (id: string) => {
    if (!id) {
      setSheet(null);
      return;
    }
    setLoading(true);
    const result = await readAnnualSheet(sessionId, id);
    setLoading(false);
    if (result.error || !result.sheet) {
      toast.error(result.error ?? 'Could not read the annual results.');
      setSheet(null);
      return;
    }
    setSheet(result.sheet);
  };

  const onCompute = async () => {
    if (!sheet) return;
    setBusy(true);
    const result = await computeAnnualResults({ sessionId, classLevelId: sheet.class_level_id });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(`${result.rows} annual results computed for the class.`);
    await load(sectionId);
  };

  const counting = sheet?.terms.filter((t) => t.counts_toward_annual) ?? [];
  const display = sheet?.terms.filter((t) => !t.counts_toward_annual) ?? [];

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="annual-section">Section</Label>
          <select
            id="annual-section"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={sectionId}
            data-testid="annual-section-select"
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
        <Button variant="outline" disabled={loading} data-testid="open-annual" onClick={() => void load(sectionId)}>
          {loading ? 'Opening…' : 'Open annual results'}
        </Button>
      </section>

      {sheet && (
        <div className="space-y-4" data-testid="annual-sheet">
          <div className="rounded-md border p-4 text-sm" data-testid="annual-weightage">
            <p className="font-medium">What the year is made of</p>
            <ul className="mt-2 space-y-1">
              {counting.map((t) => (
                <li key={t.exam_term_id} data-testid={`annual-term-${t.code}`}>
                  {t.name} — {Number(t.weight_pct).toFixed(2)}%
                  {t.ready ? '' : ' · still being marked'}
                </li>
              ))}
            </ul>
            {display.length > 0 && (
              <p className="mt-2 text-muted-foreground" data-testid="annual-non-counting">
                On the report card and outside the total:{' '}
                {display.map((t) => `${t.name} (${Number(t.weight_pct).toFixed(2)}%)`).join(', ')}.
              </p>
            )}
          </div>

          {sheet.pending_terms.length > 0 && (
            <p
              className="rounded-md border border-dashed p-4 text-sm text-muted-foreground"
              data-testid="annual-provisional-banner"
            >
              Provisional. <span data-testid="annual-pending-terms">{sheet.pending_terms.join(', ')}</span>{' '}
              {sheet.pending_terms.length === 1 ? 'is' : 'are'} still being marked for this section, so the weight below
              is pro-rated across what exists. Report cards cannot be published until every counting term is signed off.
            </p>
          )}

          {sheet.stale_count > 0 && (
            <p
              className="rounded-md border border-destructive p-4 text-sm text-destructive"
              data-testid="annual-stale-banner"
            >
              A term result changed after these were computed. {sheet.stale_count} candidate
              {sheet.stale_count === 1 ? '' : 's'} need the term recomputing first — recomputing the year on its own
              will not clear this.
            </p>
          )}

          {sheet.can_compute && (
            <Button disabled={busy} data-testid="recompute-annual" onClick={() => void onCompute()}>
              {busy ? 'Computing…' : 'Recompute this class'}
            </Button>
          )}

          {sheet.candidates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="annual-none">
              Nothing has been aggregated for this section yet.
            </p>
          ) : (
            <div className="space-y-4">
              <p className="text-xs text-muted-foreground" data-testid="annual-computed-at">
                Computed {sheet.computed_at ? new Date(sheet.computed_at).toLocaleString() : '—'}
              </p>
              {sheet.candidates.map((c) => (
                <div key={c.enrolment_id} className="space-y-2 rounded-md border p-4" data-testid={`annual-${c.gr_number}`}>
                  <div className="flex flex-wrap items-center gap-3">
                    <h2 className="text-base font-semibold">
                      {c.roll_no !== null ? `${c.roll_no}. ` : ''}
                      {c.student_name}
                    </h2>
                    <span className="text-xs text-muted-foreground">{c.gr_number}</span>
                    {c.is_blocked && (
                      <span
                        className="rounded-full border border-destructive px-2 py-0.5 text-xs text-destructive"
                        data-testid={`annual-withheld-${c.gr_number}`}
                      >
                        Result withheld — debarred this year
                      </span>
                    )}
                  </div>

                  <table className="w-full text-sm">
                    <thead className="text-left text-muted-foreground">
                      <tr>
                        <th className="py-1">Subject</th>
                        <th className="py-1">Weighted %</th>
                        <th className="py-1">Grade</th>
                        <th className="py-1">GPA</th>
                        <th className="py-1">Terms</th>
                        <th className="py-1">Result</th>
                      </tr>
                    </thead>
                    <tbody>
                      {c.subjects.map((row) => (
                        <tr key={row.subject_id} data-testid={`annual-${c.gr_number}-${row.subject_name}`}>
                          <td className="py-1 font-medium">
                            {row.subject_name}
                            {row.is_stale && (
                              <span
                                className="ml-2 text-xs text-destructive"
                                data-testid={`annual-stale-${c.gr_number}-${row.subject_name}`}
                              >
                                stale
                              </span>
                            )}
                            {row.status === 'provisional' && (
                              <span
                                className="ml-2 text-xs text-muted-foreground"
                                data-testid={`annual-status-${c.gr_number}-${row.subject_name}`}
                              >
                                provisional
                              </span>
                            )}
                          </td>
                          <td className="py-1">{pct(row)}</td>
                          <td className="py-1">{annualDisplay(row)}</td>
                          <td className="py-1">{row.gpa_point === null ? '—' : Number(row.gpa_point).toFixed(2)}</td>
                          <td className="py-1">
                            {row.proration_note ? (
                              <span data-testid={`annual-prorated-${c.gr_number}-${row.subject_name}`}>
                                {row.proration_note}
                              </span>
                            ) : (
                              `${row.terms_counted} of ${row.terms_total}`
                            )}
                          </td>
                          <td className="py-1">
                            {row.is_blocked ? (
                              <span className="text-muted-foreground">Withheld</span>
                            ) : row.is_pass === null ? (
                              <span className="text-muted-foreground">—</span>
                            ) : row.is_pass ? (
                              <span>Pass</span>
                            ) : (
                              <span className="text-destructive">Fail</span>
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
