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
