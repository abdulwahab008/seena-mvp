import { describe, expect, it } from 'vitest';
import { buildCensusCsv, buildCensusFile, buildCensusXlsx, classAgeMatrix, classGenderMatrix, fillXlsxTemplate, readZip, templateValues, type CensusCell, type CensusInput, type FrameworkSpec } from './output';
import { buildWorkbook } from '@/lib/xlsx/writer';

const spec = (format: 'csv' | 'xlsx'): FrameworkSpec => ({
  framework: 'punjab_emis',
  display_name: 'Punjab EMIS annual school census',
  output_format: format,
  cell_spec: { gender_labels: { male: 'Boys', female: 'Girls', other: 'Other' }, sheets: { class_gender: 'Enrolment by class', age: 'Enrolment by age' }, template_map: null },
});
const cells: CensusCell[] = [
  { metric: 'enrolment', dimension_key: { class_code: '1', gender: 'male' }, value: 30 },
  { metric: 'enrolment', dimension_key: { class_code: '1', gender: 'female' }, value: 28 },
  { metric: 'enrolment', dimension_key: { class_code: '2', gender: 'male' }, value: 25 },
  { metric: 'enrolment_by_age', dimension_key: { class_code: '1', age: '6' }, value: 40 },
  { metric: 'enrolment_by_age', dimension_key: { class_code: '1', age: '7' }, value: 17 },
  { metric: 'enrolment_by_age', dimension_key: { class_code: '1', age: 'unknown' }, value: 1 },
  { metric: 'enrolment_by_age', dimension_key: { class_code: '2', age: '8' }, value: 25 },
];
const input = (format: 'csv' | 'xlsx', over: Partial<CensusInput> = {}): CensusInput => ({
  cells, classes: [{ code: '2', name: 'Class 2', ordinal: 3 }, { code: '1', name: 'Class 1', ordinal: 2 }], spec: spec(format), censusDate: '2026-03-01', campusName: 'Main Campus', incomplete: true, unknownAgeCount: 1, ...over,
});

describe('census matrices', () => {
  it('lays out classes in ordinal order with row and column totals that add up', () => {
    const m = classGenderMatrix(input('csv'));
    expect(m.header).toEqual(['Class code', 'Class', 'Boys', 'Girls', 'Other', 'Total']);
    expect(m.rows[0]).toEqual(['1', 'Class 1', 30, 28, 0, 58]);
    expect(m.rows[1]).toEqual(['2', 'Class 2', 25, 0, 0, 25]);
    expect(m.rows.at(-1)).toEqual(['', 'Total', 55, 28, 0, 83]);
  });
  it('keeps an explicit unknown-age column', () => {
    const m = classAgeMatrix(input('csv'));
    expect(m.header).toContain('Age unknown');
    const unknownIdx = m.header.indexOf('Age unknown');
    expect(m.rows[0]![unknownIdx]).toBe(1);
    expect(m.rows.at(-1)!.at(-1)).toBe(83);
  });
  it('totals match across both tables', () => {
    expect(classGenderMatrix(input('csv')).rows.at(-1)!.at(-1)).toBe(classAgeMatrix(input('csv')).rows.at(-1)!.at(-1));
  });
});

describe('determinism: regenerating the same return gives the same bytes', () => {
  it('csv', async () => {
    const a = buildCensusFile(input('csv'));
    await new Promise((r) => setTimeout(r, 1100));
    const b = buildCensusFile(input('csv'));
    expect(Buffer.from(b.bytes).equals(Buffer.from(a.bytes))).toBe(true);
    expect(b.sha256).toBe(a.sha256);
  });
  it('xlsx', async () => {
    const a = buildCensusXlsx(input('xlsx'));
    await new Promise((r) => setTimeout(r, 1100));
    const b = buildCensusXlsx(input('xlsx'));
    expect(Buffer.from(b).equals(Buffer.from(a))).toBe(true);
  });
  it('changes when a cell changes', () => {
    const changed = { ...input('csv'), cells: cells.map((c, i) => (i === 0 ? { ...c, value: 31 } : c)) };
    expect(buildCensusFile(changed).sha256).not.toBe(buildCensusFile(input('csv')).sha256);
  });
});

describe('csv output', () => {
  it('opens in Excel with a BOM, flags an incomplete return, and carries no timestamp', () => {
    const bytes = buildCensusCsv(input('csv'));
    expect([...bytes.subarray(0, 3)]).toEqual([0xef, 0xbb, 0xbf]);
    const text = new TextDecoder('utf-8', { ignoreBOM: true }).decode(bytes);
    expect(text).toContain('INCOMPLETE: 1 student(s) with unknown age');
    expect(text).toContain('Census date,2026-03-01');
    expect(text).not.toMatch(/generated/i);
  });
  it('says Complete when nothing is unknown', () => {
    expect(new TextDecoder().decode(buildCensusCsv(input('csv', { incomplete: false, unknownAgeCount: 0 })))).toContain('Status,Complete');
  });
});

describe('xlsx output and template fill', () => {
  it("builds a workbook with the framework's sheet names", () => {
    const names = readZip(buildCensusXlsx(input('xlsx'))).find((e) => e.name === 'xl/workbook.xml')!;
    const xml = new TextDecoder().decode(names.data);
    expect(xml).toContain('name="Enrolment by class"');
    expect(xml).toContain('name="Enrolment by age"');
  });

  // a stand-in for a province's distributed workbook: one sheet, a styled header, a pre-existing cell
  const template = buildWorkbook([{ name: 'Enrolment', columns: [{ key: 'a', label: 'Class', type: 'text' }, { key: 'b', label: 'Boys', type: 'int' }], rows: [{ a: 'Class 1', b: 0 }] }]);

  it('maps cells to template references', () => {
    const values = templateValues(
      [
        { sheet: 'Enrolment', ref: 'B2', metric: 'enrolment', class_code: '1', gender: 'male' },
        { sheet: 'Enrolment', ref: 'C2', metric: 'enrolment', class_code: '1', gender: 'female' },
        { sheet: 'Enrolment', ref: 'D2', metric: 'total', class_code: '1' },
      ],
      cells,
    );
    expect(values.map((v) => v.value)).toEqual([30, 28, 58]);
  });
  it('fills an existing cell, adds a missing one in column order, and keeps the rest of the workbook', () => {
    const filled = fillXlsxTemplate(template, [
      { sheet: 'Enrolment', ref: 'B2', value: 30 },
      { sheet: 'Enrolment', ref: 'D2', value: 58 },
      { sheet: 'Enrolment', ref: 'B5', value: 7 },
    ]);
    const sheet = new TextDecoder().decode(readZip(filled).find((e) => e.name === 'xl/worksheets/sheet1.xml')!.data);
    expect(sheet).toMatch(/<c r="B2"[^>]*><v>30<\/v><\/c>/);
    expect(sheet).toMatch(/<c r="D2"[^>]*><v>58<\/v><\/c>/);
    expect(sheet.indexOf('r="B2"')).toBeLessThan(sheet.indexOf('r="D2"'));
    expect(sheet).toMatch(/<row r="5">.*<c r="B5"[^>]*><v>7<\/v>/);
    expect(sheet).toContain('Class 1');
    expect(readZip(filled).map((e) => e.name)).toEqual(readZip(template).map((e) => e.name));
  });
  it('is deterministic', () => {
    const v = [{ sheet: 'Enrolment', ref: 'B2', value: 30 }];
    expect(Buffer.from(fillXlsxTemplate(template, v)).equals(Buffer.from(fillXlsxTemplate(template, v)))).toBe(true);
  });
  it('refuses a template without the named sheet instead of writing somewhere else', () => {
    expect(() => fillXlsxTemplate(template, [{ sheet: 'Nope', ref: 'A1', value: 1 }])).toThrow('TEMPLATE_SHEET_NOT_FOUND');
  });
});
