// FR-T12: the file and presentation layer of the board examination form export.
//
// Pure, like lib/board-export.ts (FR-T11): the cells, the fee and the
// reconciliation all arrive computed by the database (fn_board_exam_form_rows,
// fn_board_exam_reconciliation). Nothing here prices a candidate or sums a fee —
// the same rule that keeps the printed challan and the board's figure from
// disagreeing keeps the file and the reconciliation screen from disagreeing.

import { csvCell } from '@/lib/student-import';
import { formatPkr } from '@/lib/challan/html';

const BOM = '﻿';

export type BoardExamFormRow = { registration_id: string; cells: (string | null)[] };

export function buildBoardExamFormCsv(headers: string[], rows: BoardExamFormRow[]): string {
  const lines = [headers.map(csvCell).join(',')];
  for (const row of rows) lines.push(row.cells.map((c) => csvCell(c ?? '')).join(','));
  // BOM so Excel opens Urdu names correctly; CRLF because the boards' portals are Windows tools.
  return `${BOM}${lines.join('\r\n')}\r\n`;
}

export function boardExamFormFileName(boardCode: string, sessionYear: number, exportId: string): string {
  const slug = boardCode.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toUpperCase();
  return `${slug}-EXAM-FORM-${sessionYear}-${exportId.slice(0, 8)}.csv`;
}

export type ReconciliationStudent = {
  registration_id: string;
  student_name: string;
  gr_number: string;
  candidate_category?: string;
  owed_paisa?: number;
  computed_paisa?: number;
  billed_paisa?: number;
};

export type Reconciliation = {
  board_code: string;
  candidates: number;
  computed_total_paisa: number;
  billed_total_paisa: number;
  collected_total_paisa: number;
  difference_paisa: number;
  by_category: Record<string, { candidates: number; computed_paisa: number }>;
  unpaid: ReconciliationStudent[];
  short: ReconciliationStudent[];
  billing_mismatch: ReconciliationStudent[];
  no_schedule: ReconciliationStudent[];
};

/** "PKR 817,800 computed, PKR 810,500 collected — PKR 7,300 short." in whole rupees when exact. */
export function reconciliationHeadline(r: Pick<Reconciliation, 'computed_total_paisa' | 'collected_total_paisa' | 'difference_paisa'>): string {
  const money = (paisa: number) => formatPkr(paisa).replace(/\.00$/, '');
  const base = `${money(r.computed_total_paisa)} computed, ${money(r.collected_total_paisa)} collected`;
  if (r.difference_paisa === 0) return `${base} — the deposit matches the collection.`;
  return r.difference_paisa > 0
    ? `${base} — ${money(r.difference_paisa)} short of what must be remitted.`
    : `${base} — ${money(-r.difference_paisa)} collected beyond what the board charges.`;
}

export type ExportError = {
  registration_id: string;
  student_name: string;
  gr_number: string;
  rule_code: string;
  severity: 'blocking' | 'warning';
  subject_code: string | null;
  message: string;
};

export type ExportReadiness = {
  export_id: string;
  status: 'draft' | 'completed' | 'failed';
  validated_at: string | null;
  blocking_count: number;
  warning_count: number;
  computed_total_paisa: number | null;
  collected_total_paisa: number | null;
  can_generate: boolean;
  errors: ExportError[];
};

/** Blocking first, then by student, as the controller works through them. */
export function sortErrors(errors: ExportError[]): ExportError[] {
  return [...errors].sort(
    (a, b) =>
      Number(b.severity === 'blocking') - Number(a.severity === 'blocking') ||
      a.student_name.localeCompare(b.student_name) ||
      a.rule_code.localeCompare(b.rule_code),
  );
}

export const CATEGORY_LABEL: Record<string, string> = { regular: 'Regular', improvement: 'Improvement', private: 'Private' };

export function boardExamError(message: string): string {
  if (message.includes('SCHEDULE_EXISTS')) return 'A schedule with that effective date already exists for this board, year and category.';
  if (message.includes('SCHEDULE_INVALID')) return 'A fee schedule must charge something and have an effective date.';
  if (message.includes('NO_REGISTRATIONS')) return 'No candidates are registered for that board and year at this campus.';
  if (message.includes('EXPORT_BLOCKED')) return 'Fix every blocking error before generating the file.';
  if (message.includes('EXPORT_NOT_VALIDATED')) return 'Check the data before generating the file.';
  if (message.includes('STUDENT_NOT_FOUND')) return 'Student not found.';
  if (message.includes('REGISTRATION_INVALID')) return 'The registration is incomplete: each subject needs a code and an election.';
  if (message.includes('SESSION_NOT_FOUND')) return 'Academic session not found.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete the board examination form action.';
}
