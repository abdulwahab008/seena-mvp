import { createHash } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';
import { buildWorkbook, columnLetter, xmlEscape, zip, type Column, type Sheet, type ZipEntry } from '@/lib/xlsx/writer';
import { csvLine, UTF8_BOM } from '@/lib/tenant-export/archive';

/**
 * FR-T13: turns a stored census run (its cells, nothing else) into the file a province expects.
 *
 * Determinism is a requirement, not a nicety: regenerating a return for the same census date
 * must produce a byte-identical file, so nothing time-dependent (no generation timestamp, no
 * run id) is written into it. Everything printed comes from the cells, the framework's labels,
 * the class list and the census date.
 */

export type CensusCell = { metric: 'enrolment' | 'enrolment_by_age'; dimension_key: Record<string, string>; value: number };
export type CensusClass = { code: string; name: string; ordinal: number };
export type FrameworkSpec = {
  framework: string;
  display_name: string;
  output_format: 'csv' | 'xlsx';
  cell_spec: {
    gender_labels: Record<string, string>;
    sheets: { class_gender: string; age: string };
    /** Optional cell map for filling a province's distributed workbook: [{ sheet, ref, metric, class_code, gender|age }] */
    template_map: TemplateMapEntry[] | null;
  };
};
export type TemplateMapEntry = { sheet: string; ref: string; metric: 'enrolment' | 'enrolment_by_age' | 'total'; class_code?: string; gender?: string; age?: string };
export type CensusInput = { cells: CensusCell[]; classes: CensusClass[]; spec: FrameworkSpec; censusDate: string; campusName: string; incomplete: boolean; unknownAgeCount: number };

const GENDERS = ['male', 'female', 'other'] as const;
const AGES = [...Array.from({ length: 25 }, (_, i) => String(i)), '25', 'unknown'];

export type Matrix = { header: string[]; rows: (string | number)[][] };

function lookup(cells: readonly CensusCell[], metric: CensusCell['metric'], key: Record<string, string>): number {
  return cells.filter((c) => c.metric === metric && Object.entries(key).every(([k, v]) => c.dimension_key[k] === v)).reduce((s, c) => s + c.value, 0);
}

function orderedClasses(input: CensusInput): CensusClass[] {
  const known = new Set(input.classes.map((c) => c.code));
  const strays = [...new Set(input.cells.map((c) => c.dimension_key.class_code!))].filter((c) => !known.has(c)).sort().map((code) => ({ code, name: code, ordinal: 9999 }));
  return [...input.classes].sort((a, b) => a.ordinal - b.ordinal || a.code.localeCompare(b.code)).concat(strays);
}

/** Class x gender, with row and column totals. Only classes that have students (or are in the class list) appear, in ordinal order. */
export function classGenderMatrix(input: CensusInput): Matrix {
  const labels = input.spec.cell_spec.gender_labels;
  const header = ['Class code', 'Class', ...GENDERS.map((g) => labels[g] ?? g), 'Total'];
  const rows = orderedClasses(input).map((c) => {
    const per = GENDERS.map((g) => lookup(input.cells, 'enrolment', { class_code: c.code, gender: g }));
    return [c.code, c.name, ...per, per.reduce((a, b) => a + b, 0)];
  });
  const totals = header.slice(2).map((_, i) => rows.reduce((s, r) => s + (r[2 + i] as number), 0));
  return { header, rows: [...rows, ['', 'Total', ...totals]] };
}

export function classAgeMatrix(input: CensusInput): Matrix {
  const header = ['Class code', 'Class', ...AGES.map((a) => (a === 'unknown' ? 'Age unknown' : a === '25' ? '25+' : a)), 'Total'];
  const rows = orderedClasses(input).map((c) => {
    const per = AGES.map((a) => lookup(input.cells, 'enrolment_by_age', { class_code: c.code, age: a }));
    return [c.code, c.name, ...per, per.reduce((a, b) => a + b, 0)];
  });
  const totals = header.slice(2).map((_, i) => rows.reduce((s, r) => s + (r[2 + i] as number), 0));
  return { header, rows: [...rows, ['', 'Total', ...totals]] };
}

export function buildCensusCsv(input: CensusInput): Uint8Array {
  const g = classGenderMatrix(input);
  const a = classAgeMatrix(input);
  const lines = [
    csvLine([input.spec.display_name]),
    csvLine(['Census date', input.censusDate]),
    csvLine(['Campus', input.campusName]),
    csvLine(['Status', input.incomplete ? `INCOMPLETE: ${input.unknownAgeCount} student(s) with unknown age` : 'Complete']),
    csvLine([]),
    csvLine([input.spec.cell_spec.sheets.class_gender]),
    csvLine(g.header),
    ...g.rows.map(csvLine),
    csvLine([]),
    csvLine([input.spec.cell_spec.sheets.age]),
    csvLine(a.header),
    ...a.rows.map(csvLine),
  ];
  return new TextEncoder().encode(UTF8_BOM + lines.join(''));
}

function sheetOf(name: string, m: Matrix): Sheet {
  const columns: Column[] = m.header.map((h, i) => ({ key: `c${i}`, label: h, type: i < 2 ? 'text' : 'int' }));
  return { name, columns, rows: m.rows.map((r) => Object.fromEntries(r.map((v, i) => [`c${i}`, v]))) };
}

export function buildCensusXlsx(input: CensusInput): Uint8Array {
  const sheets = [sheetOf(input.spec.cell_spec.sheets.class_gender, classGenderMatrix(input)), sheetOf(input.spec.cell_spec.sheets.age, classAgeMatrix(input))];
  const info: Sheet = {
    name: 'Return info',
    columns: [{ key: 'k', label: 'Field', type: 'text' }, { key: 'v', label: 'Value', type: 'text' }],
    rows: [
      { k: 'Return', v: input.spec.display_name },
      { k: 'Census date', v: input.censusDate },
      { k: 'Campus', v: input.campusName },
      { k: 'Status', v: input.incomplete ? `INCOMPLETE: ${input.unknownAgeCount} student(s) with unknown age` : 'Complete' },
    ],
  };
  return buildWorkbook([...sheets, info]);
}

export function buildCensusFile(input: CensusInput): { bytes: Uint8Array; sha256: string; extension: 'csv' | 'xlsx'; contentType: string } {
  const xlsx = input.spec.output_format === 'xlsx';
  const bytes = xlsx ? buildCensusXlsx(input) : buildCensusCsv(input);
  return {
    bytes,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    extension: xlsx ? 'xlsx' : 'csv',
    contentType: xlsx ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'text/csv; charset=utf-8',
  };
}

// ── template fill: a province's distributed workbook, filled cell for cell ─

/** Values to write into a distributed workbook, per its template_map. */
export function templateValues(map: readonly TemplateMapEntry[], cells: readonly CensusCell[]): { sheet: string; ref: string; value: number }[] {
  return map.map((m) => {
    const value =
      m.metric === 'total'
        ? lookup(cells, 'enrolment', m.class_code ? { class_code: m.class_code } : {})
        : lookup(cells, m.metric, { ...(m.class_code ? { class_code: m.class_code } : {}), ...(m.gender ? { gender: m.gender } : {}), ...(m.age ? { age: m.age } : {}) });
    return { sheet: m.sheet, ref: m.ref, value };
  });
}

type ReadEntry = { name: string; data: Uint8Array };

/** Reads every entry of a ZIP (stored or deflated) via its central directory. */
export function readZip(bytes: Uint8Array): ReadEntry[] {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= 0; i--) {
    if (dv.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('NOT_A_ZIP');
  const count = dv.getUint16(eocd + 10, true);
  let at = dv.getUint32(eocd + 16, true);
  const out: ReadEntry[] = [];
  for (let n = 0; n < count; n++) {
    if (dv.getUint32(at, true) !== 0x02014b50) throw new Error('ZIP_CORRUPT');
    const method = dv.getUint16(at + 10, true);
    const csize = dv.getUint32(at + 20, true);
    const nameLen = dv.getUint16(at + 28, true);
    const extraLen = dv.getUint16(at + 30, true);
    const commentLen = dv.getUint16(at + 32, true);
    const localAt = dv.getUint32(at + 42, true);
    const name = new TextDecoder().decode(bytes.subarray(at + 46, at + 46 + nameLen));
    const lNameLen = dv.getUint16(localAt + 26, true);
    const lExtraLen = dv.getUint16(localAt + 28, true);
    const start = localAt + 30 + lNameLen + lExtraLen;
    const raw = bytes.subarray(start, start + csize);
    out.push({ name, data: method === 0 ? raw : new Uint8Array(inflateRawSync(raw)) });
    at += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

function colIndex(letters: string): number {
  let n = 0;
  for (const ch of letters) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n;
}

function setCell(sheetXml: string, ref: string, value: number): string {
  const m = /^([A-Z]+)(\d+)$/.exec(ref);
  if (!m) throw new Error(`BAD_CELL_REF ${ref}`);
  const col = colIndex(m[1]!);
  const rowNo = m[2]!;
  const cellRe = new RegExp(`<c r="${ref}"([^>]*?)(?:/>|>[\\s\\S]*?</c>)`);
  const styleOf = (attrs: string) => /\ss="(\d+)"/.exec(attrs)?.[1];
  const make = (style?: string) => `<c r="${ref}"${style ? ` s="${style}"` : ''}><v>${value}</v></c>`;
  if (cellRe.test(sheetXml)) return sheetXml.replace(cellRe, (_all, attrs: string) => make(styleOf(attrs)));

  const rowRe = new RegExp(`<row r="${rowNo}"([^>]*?)(?:/>|>([\\s\\S]*?)</row>)`);
  const rowMatch = rowRe.exec(sheetXml);
  if (!rowMatch) {
    const newRow = `<row r="${rowNo}">${make()}</row>`;
    // insert in row order
    const rows = [...sheetXml.matchAll(/<row r="(\d+)"/g)].map((r) => ({ n: Number(r[1]), at: r.index! }));
    const after = rows.find((r) => r.n > Number(rowNo));
    if (after) return sheetXml.slice(0, after.at) + newRow + sheetXml.slice(after.at);
    return sheetXml.includes('</sheetData>') ? sheetXml.replace('</sheetData>', `${newRow}</sheetData>`) : sheetXml.replace(/<sheetData\s*\/>/, `<sheetData>${newRow}</sheetData>`);
  }
  const inner = rowMatch[2] ?? '';
  const cells = [...inner.matchAll(/<c r="([A-Z]+)\d+"/g)].map((c) => ({ col: colIndex(c[1]!), at: c.index! }));
  const next = cells.find((c) => c.col > col);
  const newInner = next ? inner.slice(0, next.at) + make() + inner.slice(next.at) : inner + make();
  return sheetXml.replace(rowRe, `<row r="${rowNo}"${rowMatch[1] ?? ''}>${newInner}</row>`);
}

/**
 * Writes values into a workbook the province distributed (names the sheets by their visible
 * name), leaving everything else in it exactly as it was, including its styling. The result is a
 * stored ZIP with a fixed entry order, so filling the same template with the same values twice
 * gives identical bytes.
 */
export function fillXlsxTemplate(template: Uint8Array, values: readonly { sheet: string; ref: string; value: number }[]): Uint8Array {
  const entries = readZip(template);
  const text = (name: string) => new TextDecoder().decode(entries.find((e) => e.name === name)?.data ?? new Uint8Array());
  const workbook = text('xl/workbook.xml');
  const rels = text('xl/_rels/workbook.xml.rels');
  const sheetPath = (sheetName: string): string => {
    const sheet = [...workbook.matchAll(/<sheet\b[^>]*>/g)].map((m) => m[0]).find((tag) => new RegExp(`name="${xmlEscape(sheetName)}"`).test(tag));
    const rid = sheet && /r:id="([^"]+)"/.exec(sheet)?.[1];
    const rel = rid && [...rels.matchAll(/<Relationship\b[^>]*>/g)].map((m) => m[0]).find((t) => t.includes(`Id="${rid}"`));
    const target = rel && /Target="([^"]+)"/.exec(rel)?.[1];
    if (!target) throw new Error(`TEMPLATE_SHEET_NOT_FOUND ${sheetName}`);
    return target.startsWith('/') ? target.slice(1) : `xl/${target}`;
  };
  const patched = new Map<string, string>();
  for (const v of values) {
    const path = sheetPath(v.sheet);
    patched.set(path, setCell(patched.get(path) ?? text(path), v.ref, v.value));
  }
  const enc = new TextEncoder();
  const out: ZipEntry[] = entries.map((e) => ({ name: e.name, data: patched.has(e.name) ? enc.encode(patched.get(e.name)!) : e.data }));
  return zip(out);
}

export { columnLetter };
