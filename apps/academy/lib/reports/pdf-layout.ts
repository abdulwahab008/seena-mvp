/**
 * FR-S09: the pure layout decisions behind a printed report. Kept free of any
 * renderer so they can be asserted exactly: which paper orientation, how wide
 * each column is, and what the totals row says.
 */

export type PdfColumnType = 'text' | 'int' | 'money' | 'date';
export type PdfColumn = { key: string; label: string; type: PdfColumnType };
export type PdfCell = string | number | null | undefined;
export type PdfRow = Record<string, PdfCell>;

export type Orientation = 'portrait' | 'landscape';

/** More columns than this cannot be read across an A4 portrait page. */
export const LANDSCAPE_ABOVE_COLUMNS = 8;
export const PAGE_MARGIN_MM = 10;
const A4 = { portrait: { w: 210, h: 297 }, landscape: { w: 297, h: 210 } } as const;

export function orientationFor(columnCount: number): Orientation {
  return columnCount > LANDSCAPE_ABOVE_COLUMNS ? 'landscape' : 'portrait';
}

export function usableWidthMm(orientation: Orientation): number {
  return A4[orientation].w - 2 * PAGE_MARGIN_MM;
}

/** 1800000 paisa -> "18,000.00". Latin digits and fixed grouping so the print never depends on the server's locale. */
export function formatPaisa(paisa: number): string {
  const negative = paisa < 0;
  const abs = Math.abs(Math.round(paisa));
  const whole = Math.floor(abs / 100)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${negative ? '-' : ''}${whole}.${String(abs % 100).padStart(2, '0')}`;
}

export function formatInt(n: number): string {
  return Math.round(n)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

export function cellText(col: PdfColumn, value: PdfCell): string {
  if (value === null || value === undefined || value === '') return '';
  if (col.type === 'money') return typeof value === 'number' ? formatPaisa(value) : String(value);
  if (col.type === 'int') return typeof value === 'number' ? formatInt(value) : String(value);
  return String(value);
}

const ARABIC_SCRIPT = /[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]/;
export function hasUrdu(text: string): boolean {
  return ARABIC_SCRIPT.test(text);
}

// ── column widths ─────────────────────────────────────────────────────────

const MIN_FONT_PT = 6.5;
const MAX_FONT_PT = 9;
const CELL_PADDING_MM = 3;
const MAX_CONTENT_CHARS = 40;
const SAMPLE_ROWS = 500;

/**
 * Estimated advance of a string at a font size, by character class. Deliberately
 * generous (capitals, digits and Arabic-script letters run wider than the Latin
 * average) because under-estimating is what clips text.
 */
export function estimateWidthMm(text: string, fontPt: number): number {
  let em = 0;
  for (const ch of text) {
    if (/[A-Z0-9@#%&MW]/.test(ch)) em += 0.7;
    else if (ARABIC_SCRIPT.test(ch)) em += 0.75;
    else if (/[a-z]/.test(ch)) em += 0.58;
    else if (ch === ' ') em += 0.32;
    else em += 0.45;
  }
  return em * fontPt * 0.3528;
}

export type ColumnLayout = { widthsMm: number[]; fontPt: number; fits: boolean };

/**
 * Distributes the usable width so that no cell is clipped: every column gets at
 * least the width of its longest unbreakable word (cells wrap between words), and
 * the remainder is shared in proportion to how much text the column carries. If
 * even the minimums do not fit, the font steps down until they do; `fits` is false
 * only if that still fails at the smallest legible size (the caller then fails the
 * report rather than printing clipped text).
 */
export function distributeColumnWidths(columns: readonly PdfColumn[], rows: readonly PdfRow[], usableMm: number): ColumnLayout {
  const sample = rows.slice(0, SAMPLE_ROWS);
  const stats = columns.map((c) => {
    const texts = [c.label, ...sample.map((r) => cellText(c, r[c.key]))];
    const words = [...new Set(texts.flatMap((t) => t.split(/\s+/)).filter((w) => w.length > 0))].sort((a, b) => b.length - a.length).slice(0, 20);
    const typical = [...texts].sort((a, b) => b.length - a.length)[0]!.slice(0, MAX_CONTENT_CHARS);
    return { words: words.length > 0 ? words : [' '], typical };
  });

  for (let fontPt = MAX_FONT_PT; fontPt >= MIN_FONT_PT - 1e-9; fontPt -= 0.5) {
    const mins = stats.map((s) => Math.max(...s.words.map((w) => estimateWidthMm(w, fontPt))) + CELL_PADDING_MM);
    const minSum = mins.reduce((a, b) => a + b, 0);
    if (minSum > usableMm) continue;
    const extra = usableMm - minSum;
    const want = stats.map((s, i) => Math.max(estimateWidthMm(s.typical, fontPt) + CELL_PADDING_MM - mins[i]!, 0));
    const wantSum = want.reduce((a, b) => a + b, 0);
    const widths = mins.map((m, i) => m + (wantSum > 0 ? (extra * want[i]!) / wantSum : extra / columns.length));
    const rounded = widths.map((w) => Math.floor(w * 100) / 100);
    rounded[rounded.length - 1] = Math.round((rounded[rounded.length - 1]! + (usableMm - rounded.reduce((a, b) => a + b, 0))) * 100) / 100;
    return { widthsMm: rounded, fontPt, fits: true };
  }
  const equal = Math.floor((usableMm / columns.length) * 100) / 100;
  return { widthsMm: columns.map(() => equal), fontPt: MIN_FONT_PT, fits: false };
}

// ── totals ────────────────────────────────────────────────────────────────

export type TotalsRow = { label: string; cells: Record<string, string> };

/** Sums every money column. Counts (ints) are not summed: a total of "days overdue" means nothing. */
export function totalsRow(columns: readonly PdfColumn[], rows: readonly PdfRow[]): TotalsRow | null {
  const money = columns.filter((c) => c.type === 'money');
  if (money.length === 0) return null;
  const cells: Record<string, string> = {};
  for (const c of money) cells[c.key] = formatPaisa(rows.reduce((s, r) => s + (typeof r[c.key] === 'number' ? (r[c.key] as number) : 0), 0));
  return { label: `Total (${formatInt(rows.length)} ${rows.length === 1 ? 'row' : 'rows'})`, cells };
}
