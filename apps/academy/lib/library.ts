// Library module (FR-O01..O08) shared helpers: pure logic that mirrors the database
// rules so forms can give instant feedback. The database remains the authority.

/**
 * ISBN normalisation, mirroring public.normalise_isbn13(): strips hyphens and
 * spaces, validates the checksum, upgrades an ISBN-10 to ISBN-13. Returns null
 * for a blank value and throws Error('ISBN_INVALID') for a malformed one.
 */
export function normaliseIsbn13(raw: string | null | undefined): string | null {
  if (raw == null) return null;
  const v = raw.replace(/[\s-]/g, '').toUpperCase();
  if (v === '') return null;
  if (!/^[0-9]{9}[0-9X]$/.test(v) && !/^[0-9]{13}$/.test(v)) throw new Error('ISBN_INVALID');

  const checkDigit13 = (first12: string) => {
    let sum = 0;
    for (let i = 0; i < 12; i++) sum += Number(first12[i]) * (i % 2 === 0 ? 1 : 3);
    return (10 - (sum % 10)) % 10;
  };

  if (v.length === 10) {
    let sum = 0;
    for (let i = 0; i < 10; i++) sum += (v[i] === 'X' ? 10 : Number(v[i])) * (10 - i);
    if (sum % 11 !== 0) throw new Error('ISBN_INVALID');
    const body = `978${v.slice(0, 9)}`;
    return `${body}${checkDigit13(body)}`;
  }
  if (!v.startsWith('978') && !v.startsWith('979')) throw new Error('ISBN_INVALID');
  if (checkDigit13(v.slice(0, 12)) !== Number(v[12])) throw new Error('ISBN_INVALID');
  return v;
}

export type CopyImportRow = {
  accession_no: string;
  barcode: string;
  isbn?: string;
  title_id?: string;
  shelf?: string;
  purchase_cost?: number;
  acquired_on?: string;
};

export const COPY_IMPORT_HEADER = ['accession_no', 'barcode', 'isbn', 'title_id', 'shelf', 'purchase_cost_pkr', 'acquired_on'] as const;

/**
 * FR-O02: parse the copy import CSV (header + one row per copy). Row numbers in errors are
 * 1-based data rows, the same numbering import_library_copies() reports back. PKR amounts
 * become integer paisa here and never pass through floating point after that.
 */
export function parseCopyCsv(matrix: string[][]): { rows: CopyImportRow[]; errors: { row: number; message: string }[] } {
  const errors: { row: number; message: string }[] = [];
  const header = (matrix[0] ?? []).map((h) => h.trim().toLowerCase().replace(/\s+/g, '_'));
  const idx = (name: string) => header.indexOf(name);
  if (idx('accession_no') < 0 || idx('barcode') < 0) {
    return { rows: [], errors: [{ row: 0, message: 'The header must contain accession_no and barcode.' }] };
  }
  const rows: CopyImportRow[] = [];
  matrix.slice(1).forEach((cells) => {
    if (cells.every((c) => c.trim() === '')) return;
    const row = rows.length + 1;
    const get = (name: string) => (idx(name) >= 0 ? (cells[idx(name)] ?? '').trim() : '');
    const out: CopyImportRow = { accession_no: get('accession_no'), barcode: get('barcode') };
    if (get('isbn')) out.isbn = get('isbn');
    if (get('title_id')) out.title_id = get('title_id');
    if (get('shelf')) out.shelf = get('shelf');
    const cost = get('purchase_cost_pkr');
    if (cost) {
      if (!/^\d+(\.\d{1,2})?$/.test(cost)) errors.push({ row, message: `Purchase cost "${cost}" is not an amount in PKR.` });
      else out.purchase_cost = Math.round(Number(cost) * 100);
    }
    const acquired = get('acquired_on');
    if (acquired) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(acquired) || Number.isNaN(Date.parse(acquired))) errors.push({ row, message: `Date "${acquired}" must look like 2026-08-20.` });
      else out.acquired_on = acquired;
    }
    if (!out.accession_no || !out.barcode) errors.push({ row, message: 'accession_no and barcode are both required.' });
    if (!out.isbn && !out.title_id) errors.push({ row, message: 'Give the isbn or title_id of the title this copy belongs to.' });
    rows.push(out);
  });
  return { rows, errors };
}

/** Postgres error text -> a sentence the librarian can act on. */
export function libraryErrorMessage(message: string, details?: string | null): string {
  const has = (code: string) => message.includes(code);
  if (has('ISBN_ALREADY_CATALOGUED')) return 'A title with this ISBN is already in the catalogue.';
  if (has('ISBN_INVALID')) return 'This is not a valid ISBN (check the digits).';
  if (has('TITLE_REQUIRED')) return 'Enter the title.';
  if (has('TITLE_NOT_FOUND')) return 'That title no longer exists.';
  if (has('SUBJECT_NOT_FOUND')) return 'That subject no longer exists.';
  if (has('FORBIDDEN')) return 'You do not have permission to do this.';
  if (has('DUPLICATE_ACCESSION')) return 'This accession number is already used (accession numbers are never reused).';
  if (has('DUPLICATE_BARCODE')) return 'This barcode is already registered to another copy.';
  if (has('CAMPUS_NOT_ALLOWED')) return 'You can only manage copies of your own campus.';
  if (has('COPY_NOT_FOUND')) return 'No copy has that barcode.';
  if (has('COPY_NOT_AVAILABLE')) return 'This copy is not available for issue.';
  if (has('INVALID_STATUS_CHANGE')) return 'That status change is not allowed.';
  if (has('NO_POLICY')) return 'No borrowing policy applies to this borrower yet.';
  if (has('LIMIT_EXCEEDED')) return `Borrowing limit reached${details ? ` (${details})` : ''}.`;
  if (has('BORROWER_BLOCKED')) return `Borrower is blocked for unpaid library fines${details ? `: ${details}` : ''}.`;
  if (has('BORROWER_NOT_FOUND')) return 'No borrower was found for that card.';
  if (has('NO_OPEN_LOAN')) return 'This book has no open loan to return.';
  if (has('RENEWAL_LIMIT')) return 'No renewals left on this loan.';
  if (has('RENEWAL_BLOCKED')) return 'This loan cannot be renewed because another borrower is waiting for the title.';
  if (has('DUPLICATE_RESERVATION')) return 'You already have an active reservation for this title.';
  if (has('COPIES_AVAILABLE')) return 'A copy is available now: borrow it at the counter.';
  if (has('RESERVATION_NOT_FOUND')) return 'That reservation no longer exists.';
  if (has('WRITE_OFF_EXISTS')) return 'This copy has already been written off.';
  if (has('WRITE_OFF_NOT_FOUND')) return 'That write-off no longer exists.';
  if (has('ALREADY_REVERSED')) return 'This write-off has already been reversed.';
  if (has('NO_FEE_LEDGER')) return 'The borrower has no active enrolment to post the charge to.';
  return 'Something went wrong. Please try again.';
}
