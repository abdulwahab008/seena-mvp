import { describe, expect, it } from 'vitest';
import { buildWorkbook, columnLetter, crc32, excelDateSerial, metadataSheet, xmlEscape, type Sheet } from './writer';

// Minimal reader for stored ZIPs, so the test proves the container is valid
// without trusting the writer's own bookkeeping.
function readZip(buf: Uint8Array): Record<string, string> {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let eocd = buf.length - 22;
  while (dv.getUint32(eocd, true) !== 0x06054b50) eocd--;
  const count = dv.getUint16(eocd + 10, true);
  let p = dv.getUint32(eocd + 16, true);
  const out: Record<string, string> = {};
  for (let i = 0; i < count; i++) {
    const size = dv.getUint32(p + 20, true);
    const nameLen = dv.getUint16(p + 28, true);
    const extraLen = dv.getUint16(p + 30, true);
    const commentLen = dv.getUint16(p + 32, true);
    const localOffset = dv.getUint32(p + 42, true);
    const crc = dv.getUint32(p + 16, true);
    const name = new TextDecoder().decode(buf.subarray(p + 46, p + 46 + nameLen));
    const lnLen = dv.getUint16(localOffset + 26, true);
    const leLen = dv.getUint16(localOffset + 28, true);
    const data = buf.subarray(localOffset + 30 + lnLen + leLen, localOffset + 30 + lnLen + leLen + size);
    expect(crc32(data)).toBe(crc);
    out[name] = new TextDecoder().decode(data);
    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

const sheet: Sheet = {
  name: 'Students',
  columns: [
    { key: 'gr', label: 'GR', type: 'text' },
    { key: 'dob', label: 'Date of birth', type: 'date' },
    { key: 'fee', label: 'Fee (PKR)', type: 'money' },
    { key: 'n', label: 'Count', type: 'int' },
  ],
  rows: [
    { gr: '00042', dob: '2015-03-09', fee: 850050, n: 3 },
    { gr: 'A&B <x>', dob: null, fee: null, n: 0 },
  ],
};

describe('helpers', () => {
  it('crc32 matches the standard check value', () => expect(crc32(new TextEncoder().encode('123456789'))).toBe(0xcbf43926));
  it('columnLetter counts like a spreadsheet', () => {
    expect([0, 25, 26, 27, 701, 702].map(columnLetter)).toEqual(['A', 'Z', 'AA', 'AB', 'ZZ', 'AAA']);
  });
  it('excelDateSerial uses the 1899-12-30 epoch', () => {
    expect(excelDateSerial('1900-01-01')).toBe(2);
    expect(excelDateSerial('2026-08-12')).toBe(46246);
    expect(excelDateSerial('not a date')).toBeNull();
  });
  it('xmlEscape neutralises markup and strips control characters', () => expect(xmlEscape('a<b>&"\u0001')).toBe('a&lt;b&gt;&amp;&quot;'));
});

describe('buildWorkbook', () => {
  const files = readZip(buildWorkbook([sheet, metadataSheet({ report: 'Student list', filters: { class: '9' }, requestedBy: 'Ali', generatedAt: new Date('2026-08-12T20:30:00Z') })]));

  it('contains the OOXML parts Excel requires', () => {
    for (const part of ['[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/styles.xml', 'xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml']) expect(files[part]).toBeTruthy();
  });
  it('freezes the header row', () => expect(files['xl/worksheets/sheet1.xml']).toContain('<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'));
  it('writes dates as Excel date values and amounts as numbers with two decimals, never text', () => {
    const xml = files['xl/worksheets/sheet1.xml']!;
    expect(xml).toContain('<c r="B2" s="1"><v>' + excelDateSerial('2015-03-09') + '</v></c>');
    expect(xml).toContain('<c r="C2" s="2"><v>8500.5</v></c>');
    expect(xml).not.toMatch(/<c r="C2"[^>]*t="inlineStr"/);
    expect(files['xl/styles.xml']).toContain('numFmtId="2"');
  });
  it('keeps leading zeros by writing identifiers as text, and escapes markup in cells', () => {
    const xml = files['xl/worksheets/sheet1.xml']!;
    expect(xml).toContain('>00042</t>');
    expect(xml).toContain('A&amp;B &lt;x&gt;');
  });
  it('names the report, filters, requester and the Karachi generation time on the metadata sheet', () => {
    const xml = files['xl/worksheets/sheet2.xml']!;
    expect(xml).toContain('Student list');
    expect(xml).toContain('{&quot;class&quot;:&quot;9&quot;}');
    expect(xml).toContain('Ali');
    expect(xml).toContain('13 Aug 2026'); // 20:30 UTC is 01:30 PKR the next day
  });
});
