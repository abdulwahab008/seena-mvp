// FR-T11: the file layer of the board registration export.
//
// CSV, not XLSX. Every acceptance criterion that names a format names CSV
// ("Then a CSV is produced with the board's exact 24 headers in order"), and
// FR-C14 already settled that a hand-written RFC 4180 writer beats adding
// SheetJS for this shape of file — so csvCell() is imported from there rather
// than reimplemented, and no dependency is added. board_profile.export_kind
// is where an XLSX board would declare itself if one ever turns up.
//
// Everything here is pure: no Supabase client, no fetch. The column order,
// headers, transforms and code maps all arrive already applied from
// fn_board_export_rows() — this file only turns text[] into bytes.

import { csvCell } from '@/lib/student-import';

/**
 * A byte order mark, when the profile asks for one.
 *
 * Urdu (student.name_ur) is the reason. UTF-8 carries Nastaliq perfectly
 * well; the failure is entirely at the other end, where a board clerk opens
 * the file in Excel and Excel — absent a BOM — guesses the machine's ANSI
 * codepage and renders every Urdu column as mojibake. parseCsv() in
 * student-import.ts already strips a leading BOM, so a file written here
 * round-trips back through our own importer unchanged.
 */
const BOM = '﻿';

export type BoardExportRow = { student_id: string; cells: (string | null)[] };

export function buildBoardExportCsv(
  headers: string[],
  rows: BoardExportRow[],
  options: { byteOrderMark: boolean },
): string {
  const lines = [headers.map(csvCell).join(',')];
  for (const row of rows) {
    lines.push(row.cells.map((cell) => csvCell(cell ?? '')).join(','));
  }
  // CRLF: the boards' own portals are Windows tools and a bare LF is the
  // second-most-common reason a file comes back unreadable.
  return `${options.byteOrderMark ? BOM : ''}${lines.join('\r\n')}\r\n`;
}

export function boardExportFileName(boardCode: string, classLevelCode: string, runId: string): string {
  const slug = (s: string) => s.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toUpperCase();
  return `${slug(boardCode)}-${slug(classLevelCode)}-${runId.slice(0, 8)}.csv`;
}

// ── error presentation ───────────────────────────────────────────────────

export type BoardExportRowError = {
  student_id: string;
  field_path: string;
  current_value: string | null;
  expected: string | null;
  rule_code: string;
  severity: 'blocking' | 'warning';
  normalisable: boolean;
};

const FIELD_LABELS: Record<string, string> = {
  'student.name_en': 'Candidate name',
  'student.name_ur': 'Candidate name (Urdu)',
  'student.father_name_en': "Father's name",
  'student.father_name_ur': "Father's name (Urdu)",
  'student.dob': 'Date of birth',
  'student.gender': 'Gender',
  'student.b_form_no': 'B-Form number',
  'student.religion': 'Religion',
  'guardian.father_cnic': "Father's CNIC",
  'enrolment.roll_no': 'Roll number',
  'stream.name_en': 'Group / stream',
  'consent.third_party_data_sharing': 'Consent to share data with the board',
};

export function boardExportFieldLabel(fieldPath: string): string {
  return FIELD_LABELS[fieldPath] ?? fieldPath;
}
