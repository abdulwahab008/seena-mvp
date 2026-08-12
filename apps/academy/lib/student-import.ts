// FR-C14: the file layer of the bulk student import dry run.
//
// CSV, not XLSX — see the header of
// supabase/migrations/20260731820000_bulk_student_import_dry_run.sql for
// why. Everything here is pure: no Supabase client, no fetch, no Date
// other than the injectable `today`, so the whole rule set is unit
// testable and nothing in it can write a student row.
//
// The rules below mirror real constraints in the schema. Keep them in
// sync with:
//   * student.chk_dob_reasonable  (dob in the last 25 years, not future)
//   * student.chk_bform_format    (#####-#######-#)
//   * create_student()'s B-Form normalisation (13 digits, any punctuation)
//   * public.gender enum
// The database is the gate; these are what make the dry-run report useful
// before anything reaches it.

export const STUDENT_IMPORT_COLUMNS = [
  'gr_number',
  'name_en',
  'name_ur',
  'father_name_en',
  'father_name_ur',
  'dob',
  'gender',
  'class',
  'b_form_no',
  'religion',
  'nationality',
  'blood_group',
] as const;

export type StudentImportColumn = (typeof STUDENT_IMPORT_COLUMNS)[number];

export const IMPORT_CHUNK_SIZE = 500;
export const MAX_IMPORT_FILE_SIZE = 10 * 1024 * 1024;

// Mirrors student.chk_dob_reasonable.
const MAX_AGE_YEARS = 25;

export type ImportIssueSeverity = 'error' | 'warning';
export type ImportRowSeverity = 'ok' | 'warning' | 'error';

export type ImportIssue = {
  column: string;
  code: string;
  severity: ImportIssueSeverity;
  message: string;
};

export type RawImportRow = { rowNo: number; raw: Record<string, string> };

export type NormalisedStudentRow = {
  gr_number: string | null;
  name_en: string | null;
  name_ur: string | null;
  father_name_en: string | null;
  father_name_ur: string | null;
  dob: string | null;
  gender: string | null;
  class_level_id: string | null;
  b_form_no: string | null;
  religion: string | null;
  nationality: string | null;
  blood_group: string | null;
};

export type ValidatedImportRow = RawImportRow & {
  normalised: NormalisedStudentRow;
  errors: ImportIssue[];
  severity: ImportRowSeverity;
};

export type ClassOption = { id: string; code: string; name_en: string };

// ── parsing ──────────────────────────────────────────────────────────────

/**
 * RFC 4180-shaped CSV: quoted fields may contain commas, newlines and
 * doubled quotes. Line endings are normalised up front so the state
 * machine only ever sees '\n'.
 */
export function parseCsv(text: string): string[][] {
  const src = (text.charCodeAt(0) === 0xfeff ? text.slice(1) : text).replace(/\r\n?/g, '\n');
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < src.length; i++) {
    const ch = src[i]!;
    if (inQuotes) {
      if (ch !== '"') {
        field += ch;
      } else if (src[i + 1] === '"') {
        field += '"';
        i++;
      } else {
        inQuotes = false;
      }
      continue;
    }
    if (ch === '"') inQuotes = true;
    else if (ch === ',') {
      row.push(field);
      field = '';
    } else if (ch === '\n') {
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else field += ch;
  }
  if (field !== '' || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

function normaliseHeaderCell(cell: string): string {
  return cell.trim().toLowerCase().replace(/\s+/g, '_');
}

export type HeaderCheckResult =
  | { ok: true; columns: string[] }
  | { ok: false; missing: string[]; unexpected: string[]; duplicated: string[]; message: string };

/**
 * AC: a header set that does not match the published template is rejected
 * BEFORE any row is parsed — no batch row, no upload, no report. Column
 * order and letter case do not matter; the set does.
 */
export function validateImportHeader(cells: string[]): HeaderCheckResult {
  const seen = cells.map(normaliseHeaderCell).filter((c) => c.length > 0);
  const expected = new Set<string>(STUDENT_IMPORT_COLUMNS);

  const missing = STUDENT_IMPORT_COLUMNS.filter((c) => !seen.includes(c));
  const unexpected = [...new Set(seen.filter((c) => !expected.has(c)))];
  const duplicated = [...new Set(seen.filter((c, i) => seen.indexOf(c) !== i))];

  if (missing.length === 0 && unexpected.length === 0 && duplicated.length === 0) {
    return { ok: true, columns: seen };
  }

  const parts: string[] = [];
  if (missing.length) parts.push(`missing ${missing.join(', ')}`);
  if (unexpected.length) parts.push(`unexpected ${unexpected.join(', ')}`);
  if (duplicated.length) parts.push(`repeated ${duplicated.join(', ')}`);

  return {
    ok: false,
    missing,
    unexpected,
    duplicated,
    message: `This file's columns do not match the student import template (${parts.join('; ')}). Download the template, copy your data into it, and upload again.`,
  };
}

/**
 * Maps the data lines onto the header's column names. `rowNo` is the
 * source line number in the file — line 1 is the header, so the first
 * data row is 2, matching Excel's own row gutter. Fully blank lines are
 * skipped without disturbing the numbering of the rows after them.
 */
export function toRawRows(matrix: string[][], columns: string[]): RawImportRow[] {
  const out: RawImportRow[] = [];
  for (let i = 1; i < matrix.length; i++) {
    const cells = matrix[i]!;
    if (cells.every((c) => c.trim() === '')) continue;
    const raw: Record<string, string> = {};
    columns.forEach((col, idx) => {
      raw[col] = (cells[idx] ?? '').trim();
    });
    out.push({ rowNo: i + 1, raw });
  }
  return out;
}

// ── validation ───────────────────────────────────────────────────────────

const GENDER_ALIASES: Record<string, string> = {
  m: 'male',
  male: 'male',
  f: 'female',
  female: 'female',
  o: 'other',
  other: 'other',
};

function key(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, ' ');
}

/**
 * Renders the configured classes for an error message, collapsing runs of
 * three or more consecutive numeric codes: `NUR, KG, 1..12`.
 */
export function formatClassChoices(classes: ClassOption[]): string {
  const codes = classes.map((c) => c.code);
  const parts: string[] = [];
  let i = 0;
  while (i < codes.length) {
    if (!Number.isInteger(Number(codes[i])) || codes[i]!.trim() === '') {
      parts.push(codes[i]!);
      i++;
      continue;
    }
    let j = i;
    while (j + 1 < codes.length && Number(codes[j + 1]) === Number(codes[j]) + 1) j++;
    if (j - i >= 2) {
      parts.push(`${codes[i]}..${codes[j]}`);
      i = j + 1;
    } else {
      parts.push(codes[i]!);
      i++;
    }
  }
  return parts.join(', ');
}

function parseIsoDate(value: string): Date | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const [y, m, d] = value.split('-').map(Number) as [number, number, number];
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null;
  return dt;
}

function severityOf(errors: ImportIssue[]): ImportRowSeverity {
  if (errors.some((e) => e.severity === 'error')) return 'error';
  if (errors.some((e) => e.severity === 'warning')) return 'warning';
  return 'ok';
}

/**
 * Validates every row against the configured class catalogue and against
 * the rest of the file. `today` is injectable so the date-range rule is
 * testable without freezing the clock.
 */
export function validateStudentImportRows(
  rows: RawImportRow[],
  classes: ClassOption[],
  today: Date = new Date(),
): ValidatedImportRow[] {
  const classChoices = formatClassChoices(classes);
  const classByKey = new Map<string, ClassOption>();
  for (const c of classes) {
    classByKey.set(key(c.code), c);
    classByKey.set(key(c.name_en), c);
  }

  const latestDob = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  const earliestDob = Date.UTC(today.getUTCFullYear() - MAX_AGE_YEARS, today.getUTCMonth(), today.getUTCDate());

  const validated: ValidatedImportRow[] = rows.map(({ rowNo, raw }) => {
    const errors: ImportIssue[] = [];
    const get = (column: StudentImportColumn) => (raw[column] ?? '').trim();
    const orNull = (v: string) => (v === '' ? null : v);

    const nameEn = get('name_en');
    if (nameEn === '') {
      errors.push({ column: 'name_en', code: 'REQUIRED', severity: 'error', message: 'Student name is required.' });
    }

    const dobRaw = get('dob');
    let dob: string | null = null;
    if (dobRaw === '') {
      errors.push({ column: 'dob', code: 'REQUIRED', severity: 'error', message: 'Date of birth is required.' });
    } else {
      const parsed = parseIsoDate(dobRaw);
      if (!parsed) {
        errors.push({
          column: 'dob',
          code: 'INVALID_DATE',
          severity: 'error',
          message: `'${dobRaw}' is not a valid date - use the format YYYY-MM-DD, e.g. 2016-04-12.`,
        });
      } else if (parsed.getTime() > latestDob) {
        errors.push({ column: 'dob', code: 'DOB_OUT_OF_RANGE', severity: 'error', message: 'Date of birth is in the future.' });
      } else if (parsed.getTime() < earliestDob) {
        errors.push({
          column: 'dob',
          code: 'DOB_OUT_OF_RANGE',
          severity: 'error',
          message: `Date of birth implies an age over ${MAX_AGE_YEARS}.`,
        });
      } else {
        dob = dobRaw;
      }
    }

    const genderRaw = get('gender');
    let gender: string | null = null;
    if (genderRaw === '') {
      errors.push({ column: 'gender', code: 'REQUIRED', severity: 'error', message: 'Gender is required.' });
    } else {
      const mapped = GENDER_ALIASES[key(genderRaw)];
      if (!mapped) {
        errors.push({
          column: 'gender',
          code: 'UNKNOWN_GENDER',
          severity: 'error',
          message: `Unknown gender '${genderRaw}' - expected one of male, female, other.`,
        });
      } else gender = mapped;
    }

    // AC: a class name that does not match a configured class blocks the
    // row, and the message names what the file said and what is allowed.
    const classRaw = get('class');
    let classLevelId: string | null = null;
    if (classRaw === '') {
      errors.push({
        column: 'class',
        code: 'UNKNOWN_CLASS',
        severity: 'error',
        message: `Class is required - expected one of ${classChoices}`,
      });
    } else {
      const match = classByKey.get(key(classRaw));
      if (!match) {
        errors.push({
          column: 'class',
          code: 'UNKNOWN_CLASS',
          severity: 'error',
          message: `Unknown class '${classRaw}' - expected one of ${classChoices}`,
        });
      } else classLevelId = match.id;
    }

    // AC: a missing B-Form number is a WARNING and the row stays
    // importable — it is only required downstream, at board registration.
    const bFormRaw = get('b_form_no');
    let bForm: string | null = null;
    if (bFormRaw === '') {
      errors.push({
        column: 'b_form_no',
        code: 'BFORM_MISSING',
        severity: 'warning',
        message: 'No B-Form number - the student can still be imported, but it is required before board registration.',
      });
    } else {
      const digits = bFormRaw.replace(/[^0-9]/g, '');
      if (digits.length !== 13) {
        errors.push({
          column: 'b_form_no',
          code: 'BFORM_INVALID_FORMAT',
          severity: 'error',
          message: `'${bFormRaw}' is not a valid B-Form number - it must have 13 digits, e.g. 42101-1234567-8.`,
        });
      } else {
        bForm = `${digits.slice(0, 5)}-${digits.slice(5, 12)}-${digits.slice(12)}`;
      }
    }

    const normalised: NormalisedStudentRow = {
      gr_number: orNull(get('gr_number')),
      name_en: orNull(nameEn),
      name_ur: orNull(get('name_ur')),
      father_name_en: orNull(get('father_name_en')),
      father_name_ur: orNull(get('father_name_ur')),
      dob,
      gender,
      class_level_id: classLevelId,
      b_form_no: bForm,
      religion: orNull(get('religion')),
      nationality: orNull(get('nationality')) ?? 'PK',
      blood_group: orNull(get('blood_group')),
    };

    return { rowNo, raw, normalised, errors, severity: 'ok' };
  });

  markDuplicates(validated, 'gr_number', 'GR number');
  markDuplicates(validated, 'b_form_no', 'B-Form number');

  for (const row of validated) row.severity = severityOf(row.errors);
  return validated;
}

/**
 * AC: the same GR number appearing twice WITHIN the file blocks BOTH
 * occurrences, not only the second. Rows that already carry an issue on
 * that column are left alone — one message per broken cell.
 */
function markDuplicates(rows: ValidatedImportRow[], column: 'gr_number' | 'b_form_no', label: string): void {
  const byValue = new Map<string, ValidatedImportRow[]>();
  for (const row of rows) {
    const value = row.normalised[column];
    if (!value) continue;
    const bucket = byValue.get(value);
    if (bucket) bucket.push(row);
    else byValue.set(value, [row]);
  }

  for (const [value, group] of byValue) {
    if (group.length < 2) continue;
    const where = group.map((r) => r.rowNo).join(', ');
    for (const row of group) {
      if (row.errors.some((e) => e.column === column)) continue;
      row.errors.push({
        column,
        code: 'DUPLICATE_IN_FILE',
        severity: 'error',
        message: `${label} '${value}' appears more than once in this file (rows ${where}) - every occurrence is blocked.`,
      });
    }
  }
}

// ── staging payload ──────────────────────────────────────────────────────

export type StagedImportRow = {
  row_no: number;
  raw: Record<string, string>;
  normalised: NormalisedStudentRow;
  errors: ImportIssue[];
};

export function toStagePayload(rows: ValidatedImportRow[]): StagedImportRow[] {
  return rows.map((r) => ({ row_no: r.rowNo, raw: r.raw, normalised: r.normalised, errors: r.errors }));
}

export function chunkRows<T>(rows: T[], size: number = IMPORT_CHUNK_SIZE): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < rows.length; i += size) chunks.push(rows.slice(i, i + size));
  return chunks;
}

export function buildStudentImportTemplateCsv(): string {
  const example = [
    '', // gr_number — leave blank to have one allocated at commit
    'Ayesha Khan',
    '',
    'Imran Khan',
    '',
    '2016-04-12',
    'female',
    '1',
    '42101-1234567-8',
    '',
    'PK',
    '',
  ];
  return `${STUDENT_IMPORT_COLUMNS.join(',')}\n${example.join(',')}\n`;
}
