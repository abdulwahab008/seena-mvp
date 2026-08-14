/**
 * FR-J12. The shape fn_report_card_batch_status() returns, and the one thing
 * the screen needs beside it.
 *
 * It lives here rather than next to the driver in lib/report-cards/batch.ts
 * for the same reason FR-J09's sheet types do: the driver imports the PDF
 * renderer, which reaches for Playwright's Chromium, and a client component
 * that only wants to print a progress row must not drag a browser into the
 * bundle.
 *
 * Every candidate the batch enumerated is in `items`, whatever happened to
 * them — that is the property AC2 turns on, and it is why the screen filters
 * this list rather than being handed a shorter one.
 */
export type ReportCardBatchItemStatus = 'pending' | 'rendering' | 'succeeded' | 'skipped' | 'failed';

export type ReportCardBatchItem = {
  item_id: string;
  enrolment_id: string;
  student_name: string;
  gr_number: string;
  section_name: string;
  roll_no: number | null;
  seq: number;
  status: ReportCardBatchItemStatus;
  report_card_id: string | null;
  revision_no: number | null;
  page_count: number | null;
  /** AC2's reason code. 'result_withheld', 'term_provisional', 'remark_missing', … */
  error_code: string | null;
  /** The gate's own sentence, so the batch and the print list cannot disagree. */
  error_detail: string | null;
};

export type ReportCardBatch = {
  batch_id: string;
  exam_term_id: string;
  exam_term_name: string;
  scope: 'section' | 'class' | 'campus';
  target_id: string;
  status: 'queued' | 'running' | 'completed' | 'failed';
  require_remark: boolean;
  total: number;
  succeeded: number;
  skipped: number;
  failed: number;
  /** Counted by the database: what tells a driver to come back. */
  pending: number;
  file_path: string | null;
  checksum: string | null;
  page_count: number | null;
  error: string | null;
  requested_at: string;
  completed_at: string | null;
  items: ReportCardBatchItem[];
  resumed?: boolean;
};

export function reportCardBatchDownloadPath(batchId: string): string {
  return `/api/report-cards/batches/${batchId}/download`;
}
