'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { generateReportCard, readReportCardSheet } from './actions';
import type { MarkSectionOption } from '@/lib/exams/mark-query';
import type { ReportCardSheet } from '@/lib/exams/report-card-query';
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
type Props = {
  examTermId: string;
  termName: string;
  sections: MarkSectionOption[];
};

export function ReportCardBoard({ examTermId, termName, sections }: Props) {
  const [sectionId, setSectionId] = useState('');
  const [sheet, setSheet] = useState<ReportCardSheet | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [remarks, setRemarks] = useState<Record<string, string>>({});

  const load = async (id: string) => {
    if (!id) {
      setSheet(null);
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
        <Button variant="outline" disabled={loading} data-testid="open-report-cards" onClick={() => void load(sectionId)}>
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
        </div>
      )}
    </div>
  );
}
