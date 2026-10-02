'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import {
  advanceReportCardBatch,
  generateReportCard,
  readReportCardBatch,
  readReportCardSheet,
  retryReportCardBatch,
  startReportCardBatch,
} from './actions';
import type { MarkSectionOption } from '@/lib/exams/mark-query';
import type { ReportCardSheet } from '@/lib/exams/report-card-query';
import { reportCardBatchDownloadPath, type ReportCardBatch } from '@/lib/exams/report-card-batch-query';
import type { REPORT_CARD_BATCH_SCOPES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

/**
 * FR-J09's print list: one section, one term, the pile a class teacher hands
 * out.
 *
 * Three things this screen refuses to be vague about.
 *
 *   * A card that cannot be printed says WHY, in the database's own sentence —
 *     "outstanding dues of PKR 12,000 as at 30 Jun 2026 exceed the PKR 5,000
 *     threshold", "term result is provisional — a paper is still being
 *     marked". A greyed-out button with no explanation sends the teacher to
 *     the wrong desk.
 *   * Regenerating after a correction is a NEW revision, not an edit, and the
 *     revision number is on screen next to the download so a teacher holding
 *     a printed copy can tell whether it is the current one.
 *   * The remark is the class teacher's, so it is typed here and frozen into
 *     the card; leaving it blank on a regeneration carries the previous
 *     revision's words forward rather than silently erasing them.
 */
type BatchScope = (typeof REPORT_CARD_BATCH_SCOPES)[number];

type Props = {
  examTermId: string;
  termName: string;
  campusId: string;
  sections: MarkSectionOption[];
};

/**
 * FR-J12 AC2's reason codes, as a Principal reads them. The sentence beside
 * each one is the database's own — the same sentence the single-card refusal
 * raises — so the batch's list and the print list above it cannot explain the
 * same fact two different ways.
 */
const SKIP_LABEL: Record<string, string> = {
  result_withheld: 'Result withheld',
  term_provisional: 'Term provisional',
  result_not_computed: 'No result computed',
  result_stale: 'Result stale',
  position_stale: 'Position stale',
  remark_missing: 'No remark',
  render_failed: 'Could not be rendered',
};

export function ReportCardBoard({ examTermId, termName, campusId, sections }: Props) {
  const [sectionId, setSectionId] = useState('');
  const [sheet, setSheet] = useState<ReportCardSheet | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [remarks, setRemarks] = useState<Record<string, string>>({});
  const [scope, setScope] = useState<BatchScope>('section');
  const [requireRemark, setRequireRemark] = useState(true);
  const [batch, setBatch] = useState<ReportCardBatch | null>(null);
  const [running, setRunning] = useState(false);

  const section = sections.find((s) => s.id === sectionId);
  const targetId = scope === 'section' ? sectionId : scope === 'class' ? (section?.classLevelId ?? '') : campusId;

  const load = async (id: string) => {
    if (!id) {
      setSheet(null);
      setBatch(null);
      return;
    }
    setLoading(true);
    const result = await readReportCardSheet({ examTermId, sectionId: id });
    setLoading(false);
    if (result.error || !result.sheet) {
      toast.error(result.error ?? 'Could not read the report cards.');
      setSheet(null);
      return;
    }
    setSheet(result.sheet);
  };

  /**
   * The driver, from the browser. Each round is one server action that claims,
   * renders and reports a slice, so the progress row moves while the run is
   * still going and a closed tab costs at most the slice in flight — the batch
   * itself is in the database and is picked up again where it stopped.
   */
  const drive = async (batchId: string) => {
    setRunning(true);
    for (;;) {
      const result = await advanceReportCardBatch({ batchId });
      if (result.error || !result.batch) {
        toast.error(result.error ?? 'The batch stopped.');
        if (result.batch) setBatch(result.batch);
        break;
      }
      setBatch(result.batch);
      if (result.batch.pending === 0) {
        toast.success(
          `${result.batch.succeeded} of ${result.batch.total} produced` +
            (result.batch.skipped + result.batch.failed > 0
              ? `, ${result.batch.skipped + result.batch.failed} skipped.`
              : '.'),
        );
        break;
      }
    }
    setRunning(false);
    await load(sectionId);
  };

  const onStartBatch = async () => {
    if (!targetId) return;
    const result = await startReportCardBatch({
      examTermId,
      scope,
      targetId,
      remarks,
      requireRemark,
    });
    if (result.error || !result.batch) {
      toast.error(result.error ?? 'Could not start the batch.');
      return;
    }
    setBatch(result.batch);
    await drive(result.batch.batch_id);
  };

  const onRetryBatch = async () => {
    if (!batch) return;
    const result = await retryReportCardBatch({ batchId: batch.batch_id, remarks });
    if (result.error || !result.batch) {
      toast.error(result.error ?? 'Could not re-run the batch.');
      return;
    }
    setBatch(result.batch);
    await drive(result.batch.batch_id);
  };

  const onLoadBatch = async (next: BatchScope) => {
    setScope(next);
    setBatch(null);
    const target = next === 'section' ? sectionId : next === 'class' ? (section?.classLevelId ?? '') : campusId;
    if (!target) return;
    const result = await readReportCardBatch({ examTermId, scope: next, targetId: target });
    if (!result.error && result.batch) setBatch(result.batch);
  };

  const onGenerate = async (enrolmentId: string) => {
    setBusy(enrolmentId);
    const result = await generateReportCard({ examTermId, enrolmentId, remark: remarks[enrolmentId] || undefined });
    setBusy(null);
    if (result.error) {
      toast.error(result.error);
      await load(sectionId);
      return;
    }
    toast.success(`Revision ${result.revisionNo} produced.`);
    await load(sectionId);
  };

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="report-card-section">Section</Label>
          <select
            id="report-card-section"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={sectionId}
            data-testid="report-card-section-select"
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
        <Button
          variant="outline"
          disabled={loading}
          data-testid="open-report-cards"
          onClick={() => void load(sectionId).then(() => onLoadBatch(scope))}
        >
          {loading ? 'Opening…' : 'Open report cards'}
        </Button>
      </section>

      {sheet && (
        <div className="space-y-4" data-testid="report-card-sheet">
          <p className="rounded-md border p-4 text-sm" data-testid="report-card-rules">
            One A4 page per candidate for {termName}: every subject, the aggregate and its grade on the scale this
            session was graded on, the position, and the attendance summary with the exact dates it covers. Branding
            comes from the campus&rsquo;s own logo and signature — there is nothing to configure per card. Regenerating
            after a correction issues the next revision and the footer says which one it supersedes.
          </p>

          {sheet.candidates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="report-card-none">
              No active candidates in this section.
            </p>
          ) : (
            <table className="w-full text-sm">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="py-1">Candidate</th>
                  <th className="py-1">Current card</th>
                  <th className="py-1">Class teacher&rsquo;s remark</th>
                  <th className="py-1" />
                </tr>
              </thead>
              <tbody>
                {sheet.candidates.map((c) => (
                  <tr key={c.enrolment_id} data-testid={`report-card-${c.gr_number}`} className="align-top">
                    <td className="py-1 font-medium">
                      {c.roll_no !== null ? `${c.roll_no}. ` : ''}
                      {c.student_name}
                      <span className="ml-2 text-xs text-muted-foreground">{c.gr_number}</span>
                    </td>
                    <td className="py-1">
                      {c.report_card_id ? (
                        <a
                          className="underline"
                          href={`/api/report-cards/${c.report_card_id}/download`}
                          target="_blank"
                          rel="noreferrer"
                          data-testid={`download-report-card-${c.gr_number}`}
                        >
                          Revision {c.revision_no}
                        </a>
                      ) : (
                        <span className="text-muted-foreground" data-testid={`no-report-card-${c.gr_number}`}>
                          Not produced yet
                        </span>
                      )}
                      {c.blocked_reason && (
                        <p className="text-xs text-destructive" data-testid={`report-card-blocked-${c.gr_number}`}>
                          {c.blocked_reason}
                        </p>
                      )}
                    </td>
                    <td className="py-1">
                      <input
                        className="h-8 w-full rounded-md border bg-background px-2 text-sm"
                        placeholder={c.revision_no ? 'Leave blank to keep the current remark' : 'Optional'}
                        value={remarks[c.enrolment_id] ?? ''}
                        data-testid={`report-card-remark-${c.gr_number}`}
                        onChange={(e) => setRemarks((r) => ({ ...r, [c.enrolment_id]: e.target.value }))}
                      />
                    </td>
                    <td className="py-1 text-right">
                      {sheet.can_print && (
                        <Button
                          size="sm"
                          variant={c.report_card_id ? 'outline' : 'default'}
                          disabled={busy !== null || c.blocked_reason !== null}
                          data-testid={`generate-report-card-${c.gr_number}`}
                          onClick={() => void onGenerate(c.enrolment_id)}
                        >
                          {busy === c.enrolment_id ? 'Producing…' : c.report_card_id ? 'Regenerate' : 'Produce card'}
                        </Button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          {sheet.can_print && (
            <section className="space-y-3 rounded-lg border p-4" data-testid="report-card-batch">
              <div>
                <h3 className="font-semibold">Print the whole {scope === 'section' ? 'section' : scope}</h3>
                <p className="mt-1 text-sm text-muted-foreground">
                  FR-J12 — one action produces every card in scope plus a single merged file ordered by section then
                  roll number, with each card starting on its own sheet so duplex printing cannot put two children on
                  one page. A candidate who cannot be printed does not stop the run: they are listed below with the
                  reason, and re-running renders only them while the merged file is rebuilt in full.
                </p>
              </div>

              <div className="flex flex-wrap items-end gap-3">
                <div className="space-y-1">
                  <Label htmlFor="report-card-batch-scope">Scope</Label>
                  <select
                    id="report-card-batch-scope"
                    className="h-9 rounded-md border bg-background px-3 text-sm"
                    value={scope}
                    data-testid="report-card-batch-scope"
                    disabled={running}
                    onChange={(e) => void onLoadBatch(e.target.value as BatchScope)}
                  >
                    <option value="section">This section</option>
                    <option value="class">Whole class</option>
                    <option value="campus">Whole campus</option>
                  </select>
                </div>
                <label className="flex h-9 items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={requireRemark}
                    data-testid="report-card-batch-require-remark"
                    disabled={running}
                    onChange={(e) => setRequireRemark(e.target.checked)}
                  />
                  Skip candidates with no class teacher&rsquo;s remark
                </label>
                <Button
                  disabled={running || !targetId}
                  data-testid="start-report-card-batch"
                  onClick={() => void onStartBatch()}
                >
                  {running ? 'Producing…' : 'Produce all cards'}
                </Button>
                {batch && !running && (batch.skipped > 0 || batch.failed > 0) && (
                  <Button variant="outline" data-testid="retry-report-card-batch" onClick={() => void onRetryBatch()}>
                    Re-run the {batch.skipped + batch.failed} skipped
                  </Button>
                )}
              </div>

              {batch && (
                <div className="space-y-3" data-testid="report-card-batch-progress">
                  <p className="text-sm">
                    <span data-testid="report-card-batch-status">{batch.status}</span> &middot;{' '}
                    <span data-testid="report-card-batch-counts">
                      {batch.succeeded} produced, {batch.skipped} skipped, {batch.failed} failed, of {batch.total}
                    </span>
                    {batch.pending > 0 && <span data-testid="report-card-batch-pending"> &middot; {batch.pending} to go</span>}
                  </p>

                  {batch.checksum && (
                    <a
                      className="inline-block underline"
                      href={reportCardBatchDownloadPath(batch.batch_id)}
                      target="_blank"
                      rel="noreferrer"
                      data-testid="download-report-card-batch"
                    >
                      Download the merged file ({batch.page_count} pages)
                    </a>
                  )}
                  {batch.error && (
                    <p className="text-sm text-destructive" data-testid="report-card-batch-error">
                      {batch.error}
                    </p>
                  )}

                  {batch.items.some((i) => i.status === 'skipped' || i.status === 'failed') && (
                    <table className="w-full text-sm" data-testid="report-card-batch-skips">
                      <thead className="text-left text-muted-foreground">
                        <tr>
                          <th className="py-1">Not produced</th>
                          <th className="py-1">Reason</th>
                        </tr>
                      </thead>
                      <tbody>
                        {batch.items
                          .filter((i) => i.status === 'skipped' || i.status === 'failed')
                          .map((i) => (
                            <tr key={i.item_id} data-testid={`batch-skip-${i.gr_number}`} className="align-top">
                              <td className="py-1 font-medium">
                                {i.roll_no !== null ? `${i.roll_no}. ` : ''}
                                {i.student_name}
                                <span className="ml-2 text-xs text-muted-foreground">{i.section_name}</span>
                              </td>
                              <td className="py-1">
                                <span
                                  className="font-medium text-destructive"
                                  data-testid={`batch-skip-code-${i.gr_number}`}
                                >
                                  {SKIP_LABEL[i.error_code ?? ''] ?? i.error_code}
                                </span>
                                {i.error_detail && (
                                  <p className="text-xs text-muted-foreground">{i.error_detail}</p>
                                )}
                              </td>
                            </tr>
                          ))}
                      </tbody>
                    </table>
                  )}
                </div>
              )}
            </section>
          )}
        </div>
      )}
    </div>
  );
}
