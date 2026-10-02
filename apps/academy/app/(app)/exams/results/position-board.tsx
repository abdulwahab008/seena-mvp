'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { computePositions, readPositionSheet, setRankPolicy } from './actions';
import type { MarkClassOption } from '@/lib/exams/mark-query';
import type { PositionSheet, RankPolicy } from '@/lib/exams/position-query';
import { RANK_POLICY_LABELS, exclusionLabel, positionDisplay } from '@/lib/exams/position-query';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

/**
 * FR-J05's merit list: one term, one whole class, both positions.
 *
 * Three things this screen refuses to be vague about.
 *
 *   * Ties SHARE a position and the next one is not skipped — 480, 472, 472,
 *     465 are 1, 2, 2, 3. The FR's Notes say parents litigate this, so it is
 *     written on the screen in words rather than left implicit in the numbers.
 *   * The "out of" is the number of candidates actually RANKED, which is not
 *     the section strength once anyone is excluded. Both figures are shown.
 *   * A candidate with no position gets a dash and the reason beside it. A
 *     blank cell would read as "not computed yet", which is a different fact.
 */
type Props = {
  examTermId: string;
  termName: string;
  campusId: string;
  classes: MarkClassOption[];
};

export function PositionBoard({ examTermId, termName, campusId, classes }: Props) {
  const [classLevelId, setClassLevelId] = useState('');
  const [sheet, setSheet] = useState<PositionSheet | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = async (id: string) => {
    if (!id) {
      setSheet(null);
      return;
    }
    setLoading(true);
    const result = await readPositionSheet(examTermId, id);
    setLoading(false);
    if (result.error || !result.sheet) {
      toast.error(result.error ?? 'Could not read the merit list.');
      setSheet(null);
      return;
    }
    setSheet(result.sheet);
  };

  const onCompute = async () => {
    setBusy(true);
    const result = await computePositions({ examTermId, classLevelId });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(`${result.rows} candidates ranked.`);
    await load(classLevelId);
  };

  const onPolicy = async (policy: RankPolicy) => {
    setBusy(true);
    const result = await setRankPolicy({ campusId, policy });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success('Ranking policy saved. Re-rank the class to apply it.');
    await load(classLevelId);
  };

  const ranked = sheet?.candidates.filter((c) => c.is_ranked) ?? [];

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="position-class">Class</Label>
          <select
            id="position-class"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={classLevelId}
            data-testid="position-class-select"
            onChange={(e) => {
              setClassLevelId(e.target.value);
              setSheet(null);
            }}
          >
            <option value="">Choose a class…</option>
            {classes.map((c) => (
              <option key={c.id} value={c.id}>
                {c.label}
              </option>
            ))}
          </select>
        </div>
        <Button variant="outline" disabled={loading} data-testid="open-positions" onClick={() => void load(classLevelId)}>
          {loading ? 'Opening…' : 'Open merit list'}
        </Button>
      </section>

      {sheet && (
        <div className="space-y-4" data-testid="position-sheet">
          <div className="rounded-md border p-4 text-sm" data-testid="position-rules">
            <p>
              {termName} positions are ranked on total marks obtained. Candidates on the same total{' '}
              <span className="font-semibold">share a position</span>, and the next position is not skipped — 480, 472,
              472 and 465 are positions 1, 2, 2 and 3. Ties are not broken.
            </p>
            <p className="mt-2" data-testid="position-policy">
              {RANK_POLICY_LABELS[sheet.rank_policy]}.
            </p>
            {sheet.can_compute && (
              <div className="mt-3 space-y-1">
                <Label htmlFor="rank-policy">Who is ranked</Label>
                <select
                  id="rank-policy"
                  className="h-9 rounded-md border bg-background px-3 text-sm"
                  value={sheet.rank_policy}
                  disabled={busy}
                  data-testid="rank-policy-select"
                  onChange={(e) => void onPolicy(e.target.value as RankPolicy)}
                >
                  <option value="exclude_absentees">Exclude absentees</option>
                  <option value="include_all">Include everyone</option>
                </select>
              </div>
            )}
          </div>

          {!sheet.readiness.ready && (
            <p
              className="rounded-md border border-dashed p-4 text-sm text-muted-foreground"
              data-testid="position-not-ready"
            >
              {sheet.readiness.ready_count} of {sheet.readiness.section_count} sections signed off. A class position is
              against the whole class, so nothing is ranked until{' '}
              <span data-testid="position-pending-sections">{sheet.readiness.pending_sections.join(', ')}</span>{' '}
              {sheet.readiness.pending_sections.length === 1 ? 'is' : 'are'} in.
            </p>
          )}

          {sheet.is_stale && (
            <p
              className="rounded-md border border-destructive p-4 text-sm text-destructive"
              data-testid="position-stale-banner"
            >
              A mark changed somewhere in this class after these positions were computed. Every position here is out of
              date, not just the candidate whose marks moved — recompute the term results first, because re-ranking on
              its own will not clear this.
            </p>
          )}

          {sheet.can_compute && (
            <Button disabled={busy} data-testid="recompute-positions" onClick={() => void onCompute()}>
              {busy ? 'Ranking…' : 'Re-rank this class'}
            </Button>
          )}

          {sheet.candidates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="position-none">
              Nothing has been ranked for this class yet.
            </p>
          ) : (
            <div className="space-y-2">
              <p className="text-xs text-muted-foreground" data-testid="position-computed-at">
                Computed {sheet.computed_at ? new Date(sheet.computed_at).toLocaleString() : '—'} ·{' '}
                <span data-testid="position-ranked-count">
                  {ranked.length} of {sheet.candidates.length} candidates ranked
                </span>
              </p>
              <table className="w-full text-sm">
                <thead className="text-left text-muted-foreground">
                  <tr>
                    <th className="py-1">Candidate</th>
                    <th className="py-1">Section</th>
                    <th className="py-1">Total</th>
                    <th className="py-1">Position in section</th>
                    <th className="py-1">Position in class</th>
                  </tr>
                </thead>
                <tbody>
                  {sheet.candidates.map((c) => (
                    <tr key={c.enrolment_id} data-testid={`position-${c.gr_number}`}>
                      <td className="py-1 font-medium">
                        {c.roll_no !== null ? `${c.roll_no}. ` : ''}
                        {c.student_name}
                        <span className="ml-2 text-xs text-muted-foreground">{c.gr_number}</span>
                      </td>
                      <td className="py-1">{c.section_name}</td>
                      <td className="py-1">
                        {Number(c.total_obtained).toFixed(2)} / {c.total_max}
                      </td>
                      <td className="py-1" data-testid={`position-section-${c.gr_number}`}>
                        {positionDisplay(c.rank_in_section, c.ranked_out_of)}
                      </td>
                      <td className="py-1">
                        <span data-testid={`position-class-${c.gr_number}`}>
                          {positionDisplay(c.rank_in_class, c.ranked_out_of_class)}
                        </span>
                        {!c.is_ranked && (
                          <span
                            className="ml-2 text-xs text-muted-foreground"
                            data-testid={`position-excluded-${c.gr_number}`}
                          >
                            {exclusionLabel(c.exclusion_reason)}
                          </span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
