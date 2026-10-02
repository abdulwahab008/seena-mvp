export type AmountSignRule = 'credit_positive' | 'separate_columns' | 'absolute';
export type DateFormat = 'DD/MM/YYYY' | 'DD-MM-YYYY' | 'YYYY-MM-DD' | 'DD-Mon-YYYY';

export type MappingProfile = {
  columnMap: { txn_date: string; challan_ref: string; bank_ref: string; amount?: string; debit?: string; credit?: string };
  dateFormat: DateFormat;
  amountSignRule: AmountSignRule;
};

export type ParsedLine = {
  line_no: number;
  txn_date: string | null;
  challan_ref: string | null;
  amount_paisa: number | null;
  bank_ref: string | null;
  raw_line: string;
  error: string | null;
};

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

// Minimal RFC 4180 reader: quoted fields, doubled quotes, CRLF/LF, BOM.
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;
  const src = text.replace(/^﻿/, '');
  for (let i = 0; i < src.length; i++) {
    const c = src[i]!;
    if (quoted) {
      if (c === '"') {
        if (src[i + 1] === '"') {
          field += '"';
          i++;
        } else quoted = false;
      } else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') {
      row.push(field);
      field = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else field += c;
  }
  if (field !== '' || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((r) => r.some((f) => f.trim() !== ''));
}

// Decimal-string arithmetic only: money never passes through a float.
export function parseAmountToPaisa(input: string): number | null {
  const s = input.replace(/\b(rs|pkr)\b\.?/gi, '').replace(/[,\s]/g, '');
  const m = /^(-?)(\d+)(?:\.(\d{1,2}))?$/.exec(s);
  if (!m) return null;
  const paisa = Number(m[2]) * 100 + Number((m[3] ?? '').padEnd(2, '0') || '0');
  return m[1] ? -paisa : paisa;
}

export function parseDate(input: string, format: DateFormat): string | null {
  const s = input.trim();
  let y: number, mo: number, d: number;
  if (format === 'YYYY-MM-DD') {
    const m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(s);
    if (!m) return null;
    [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  } else if (format === 'DD-Mon-YYYY') {
    const m = /^(\d{1,2})-([A-Za-z]{3})-(\d{4})$/.exec(s);
    if (!m) return null;
    mo = MONTHS.indexOf(m[2]!.toLowerCase()) + 1;
    [y, d] = [Number(m[3]), Number(m[1])];
  } else {
    const sep = format === 'DD/MM/YYYY' ? '/' : '-';
    const m = new RegExp(`^(\\d{1,2})\\${sep}(\\d{1,2})\\${sep}(\\d{4})$`).exec(s);
    if (!m) return null;
    [d, mo, y] = [Number(m[1]), Number(m[2]), Number(m[3])];
  }
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (mo < 1 || dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return null;
  return `${String(y).padStart(4, '0')}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

// Excel drops leading zeros on numeric-looking challan numbers: read as text,
// keep digits, left-pad to the 12 digits a challan number always has.
export function normalizeChallanRef(input: string): string | null {
  const digits = input.replace(/\D/g, '');
  if (digits === '' || digits.length > 12) return null;
  return digits.padStart(12, '0');
}

export function detectHeader(csv: string): string[] {
  return parseCsv(csv)[0]?.map((h) => h.trim()) ?? [];
}

export function parseStatement(csv: string, profile: MappingProfile): { header: string[]; lines: ParsedLine[]; fatal: string | null } {
  const rows = parseCsv(csv);
  const header = (rows[0] ?? []).map((h) => h.trim());
  const col = (name: string | undefined) => (name ? header.indexOf(name) : -1);
  const need: (string | undefined)[] = [profile.columnMap.txn_date, profile.columnMap.challan_ref, profile.columnMap.bank_ref];
  need.push(...(profile.amountSignRule === 'separate_columns' ? [profile.columnMap.debit, profile.columnMap.credit] : [profile.columnMap.amount]));
  const missing = need.filter((n) => col(n) < 0);
  if (missing.length > 0) return { header, lines: [], fatal: `Columns not found in the file: ${missing.map((m) => m ?? '(unmapped)').join(', ')}` };

  const lines: ParsedLine[] = rows.slice(1).map((r, idx) => {
    const line_no = idx + 2;
    const raw_line = r.join(',');
    const get = (name: string | undefined) => (r[col(name)] ?? '').trim();
    const errors: string[] = [];

    const txn_date = parseDate(get(profile.columnMap.txn_date), profile.dateFormat);
    if (!txn_date) errors.push('BAD_DATE');
    const challan_ref = normalizeChallanRef(get(profile.columnMap.challan_ref));
    if (!challan_ref) errors.push('MISSING_OR_BAD_CHALLAN_REF');
    const bank_ref = get(profile.columnMap.bank_ref) || null;
    if (!bank_ref) errors.push('MISSING_BANK_REF');

    let amount_paisa: number | null;
    if (profile.amountSignRule === 'separate_columns') {
      const credit = parseAmountToPaisa(get(profile.columnMap.credit) || '0');
      amount_paisa = credit;
    } else {
      amount_paisa = parseAmountToPaisa(get(profile.columnMap.amount));
      if (amount_paisa !== null && profile.amountSignRule === 'absolute') amount_paisa = Math.abs(amount_paisa);
    }
    if (amount_paisa === null) errors.push('BAD_AMOUNT');
    else if (amount_paisa <= 0) errors.push('NOT_A_CREDIT');

    if (errors.length > 0) return { line_no, txn_date: null, challan_ref: null, amount_paisa: null, bank_ref: null, raw_line, error: errors.join(',') };
    return { line_no, txn_date, challan_ref, amount_paisa, bank_ref, raw_line, error: null };
  });
  return { header, lines, fatal: null };
}
