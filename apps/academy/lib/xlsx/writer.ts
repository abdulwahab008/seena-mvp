// A dependency-free XLSX writer: just enough OOXML for typed, frozen-header
// exports (text, integers, 2-decimal amounts, real Excel dates) plus a
// metadata sheet. Amounts are numeric cells — never text — because text
// amounts break accountants' pivot tables the moment the file is opened.
//
// The ZIP container uses method 0 (stored): the workbook is read once, so
// compression buys little and "stored" keeps this writer a few dozen lines
// with no compression dependency.

export type ColumnType = 'text' | 'int' | 'money' | 'date';
export type Column = { key: string; label: string; type: ColumnType };
export type Cell = string | number | null | undefined;
export type Sheet = { name: string; columns: Column[]; rows: Record<string, Cell>[] };

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(buf: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]!) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function xmlEscape(s: string): string {
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]!);
}

export function columnLetter(index: number): string {
  let n = index + 1;
  let s = '';
  while (n > 0) {
    const r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

// Excel stores dates as days since 1899-12-30.
export function excelDateSerial(iso: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  if (!m) return null;
  const ms = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  if (Number.isNaN(ms)) return null;
  return Math.round((ms - Date.UTC(1899, 11, 30)) / 86_400_000);
}

const STYLE = { general: 0, date: 1, money: 2, header: 3 } as const;

function cellXml(col: Column, value: Cell, ref: string): string {
  if (value === null || value === undefined || value === '') return '';
  if (col.type === 'date' && typeof value === 'string') {
    const serial = excelDateSerial(value);
    if (serial !== null) return `<c r="${ref}" s="${STYLE.date}"><v>${serial}</v></c>`;
  }
  if ((col.type === 'money' || col.type === 'int') && typeof value === 'number' && Number.isFinite(value)) {
    const v = col.type === 'money' ? value / 100 : value;
    return `<c r="${ref}" s="${col.type === 'money' ? STYLE.money : STYLE.general}"><v>${v}</v></c>`;
  }
  return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${xmlEscape(String(value))}</t></is></c>`;
}

function sheetXml(sheet: Sheet): string {
  const head = sheet.columns.map((c, i) => `<c r="${columnLetter(i)}1" s="${STYLE.header}" t="inlineStr"><is><t>${xmlEscape(c.label)}</t></is></c>`).join('');
  const body = sheet.rows
    .map((row, r) => `<row r="${r + 2}">${sheet.columns.map((c, i) => cellXml(c, row[c.key], `${columnLetter(i)}${r + 2}`)).join('')}</row>`)
    .join('');
  const cols = sheet.columns.map((c, i) => `<col min="${i + 1}" max="${i + 1}" width="${Math.max(12, Math.min(40, c.label.length + 4))}" customWidth="1"/>`).join('');
  return (
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
    `<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>` +
    `<cols>${cols}</cols><sheetData><row r="1">${head}</row>${body}</sheetData></worksheet>`
  );
}

const STYLES_XML =
  `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
  `<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
  `<numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/></numFmts>` +
  `<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>` +
  `<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>` +
  `<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>` +
  `<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>` +
  `<cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>` +
  `<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>` +
  `<xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>` +
  `<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>` +
  `<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`;

export type ZipEntry = { name: string; data: Uint8Array };
type Entry = ZipEntry;

// Stored (uncompressed) ZIP container. Shared by the workbook writer and the tenant data export.
export function zip(entries: Entry[]): Uint8Array {
  const enc = new TextEncoder();
  const parts: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;
  const u16 = (n: number) => Uint8Array.of(n & 0xff, (n >>> 8) & 0xff);
  const u32 = (n: number) => Uint8Array.of(n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff);
  const cat = (...a: Uint8Array[]) => {
    const out = new Uint8Array(a.reduce((s, x) => s + x.length, 0));
    let o = 0;
    for (const x of a) {
      out.set(x, o);
      o += x.length;
    }
    return out;
  };
  for (const e of entries) {
    const name = enc.encode(e.name);
    const crc = crc32(e.data);
    const local = cat(u32(0x04034b50), u16(20), u16(0x0800), u16(0), u16(0), u16(0x21), u32(crc), u32(e.data.length), u32(e.data.length), u16(name.length), u16(0), name, e.data);
    central.push(cat(u32(0x02014b50), u16(20), u16(20), u16(0x0800), u16(0), u16(0), u16(0x21), u32(crc), u32(e.data.length), u32(e.data.length), u16(name.length), u16(0), u16(0), u16(0), u16(0), u32(0), u32(offset), name));
    parts.push(local);
    offset += local.length;
  }
  const cd = cat(...central);
  return cat(...parts, cd, u32(0x06054b50), u16(0), u16(0), u16(entries.length), u16(entries.length), u32(cd.length), u32(offset), u16(0));
}

export function buildWorkbook(sheets: Sheet[]): Uint8Array {
  const enc = new TextEncoder();
  const sheetNames = sheets.map((s) => xmlEscape(s.name.slice(0, 31)));
  const entries: Entry[] = [
    {
      name: '[Content_Types].xml',
      data: enc.encode(
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
          `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>` +
          `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
          `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>` +
          sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('') +
          `</Types>`,
      ),
    },
    {
      name: '_rels/.rels',
      data: enc.encode(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`),
    },
    {
      name: 'xl/workbook.xml',
      data: enc.encode(
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>` +
          sheetNames.map((n, i) => `<sheet name="${n}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('') +
          `</sheets></workbook>`,
      ),
    },
    {
      name: 'xl/_rels/workbook.xml.rels',
      data: enc.encode(
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
          sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('') +
          `<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`,
      ),
    },
    { name: 'xl/styles.xml', data: enc.encode(STYLES_XML) },
    ...sheets.map((s, i) => ({ name: `xl/worksheets/sheet${i + 1}.xml`, data: enc.encode(sheetXml(s)) })),
  ];
  return zip(entries);
}

// The sheet every export carries: what it is, what was applied, who asked, when (Asia/Karachi).
export function metadataSheet(info: { report: string; filters: Record<string, unknown>; requestedBy: string; generatedAt: Date }): Sheet {
  const karachi = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Karachi', dateStyle: 'medium', timeStyle: 'medium', hourCycle: 'h23' }).format(info.generatedAt);
  return {
    name: 'Report info',
    columns: [
      { key: 'k', label: 'Field', type: 'text' },
      { key: 'v', label: 'Value', type: 'text' },
    ],
    rows: [
      { k: 'Report', v: info.report },
      { k: 'Filters', v: Object.keys(info.filters).length ? JSON.stringify(info.filters) : 'none' },
      { k: 'Requested by', v: info.requestedBy },
      { k: 'Generated (Asia/Karachi)', v: karachi },
    ],
  };
}
