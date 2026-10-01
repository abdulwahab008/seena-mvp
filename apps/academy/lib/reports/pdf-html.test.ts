import { describe, expect, it } from 'vitest';
import { buildReportPdf, type ReportBranding } from './pdf-html';
import type { PdfColumn, PdfRow } from './pdf-layout';

const columns: PdfColumn[] = [
  { key: 'gr', label: 'GR number', type: 'text' },
  { key: 'name', label: 'Student', type: 'text' },
  { key: 'amt', label: 'Amount (PKR)', type: 'money' },
];
const rows: PdfRow[] = Array.from({ length: 5 }, (_, i) => ({ gr: `GR${i + 1}`, name: i === 0 ? 'عائشہ احمد' : `Student ${i}`, amt: 100000 * (i + 1) }));
const branding = (over: Partial<ReportBranding> = {}): ReportBranding => ({ header_mode: 'logo', tenant_name: 'Seena School', campus_name: 'Main Campus', address_en: '12 Canal Road', ...over });
const base = { title: 'Fee collection', columns, rows, branding: branding(), images: { letterheadDataUri: null, logoDataUri: 'data:image/png;base64,AAAA' }, generatedAt: new Date('2026-10-01T10:00:00Z'), font: null };

describe('buildReportPdf', () => {
  it('puts the identity block and the column headings in <thead> so they repeat on every page', () => {
    const { document } = buildReportPdf(base);
    const thead = /<thead>([\s\S]*?)<\/thead>/.exec(document.html)![1]!;
    expect(thead).toContain('Seena School');
    expect(thead).toContain('GR number');
    expect(document.html).toContain('thead { display: table-header-group; }');
  });
  it('never splits a row across pages', () => {
    expect(buildReportPdf(base).document.html).toContain('tr { break-inside: avoid; page-break-inside: avoid; }');
  });
  it('renders the totals row once, as the last body row (a <tfoot> would repeat on every page)', () => {
    const { document } = buildReportPdf(base);
    expect(document.html.match(/class="totals"/g)).toHaveLength(1);
    expect(document.html).not.toContain('<tfoot');
    expect(document.html).toContain('Total (5 rows)');
    expect(document.html).toContain('15,000.00');
    const bodyRows = /<tbody>([\s\S]*)<\/tbody>/.exec(document.html)![1]!;
    expect(bodyRows.trimEnd().endsWith('</tr>')).toBe(true);
    expect(bodyRows.lastIndexOf('class="totals"')).toBeGreaterThan(bodyRows.lastIndexOf('GR5'));
  });
  it('selects landscape automatically above 8 columns and portrait otherwise', () => {
    expect(buildReportPdf(base).orientation).toBe('portrait');
    expect(buildReportPdf(base).document.html).toContain('size: A4 portrait');
    const many: PdfColumn[] = Array.from({ length: 10 }, (_, i) => ({ key: `k${i}`, label: `Col ${i}`, type: 'text' }));
    const wide = buildReportPdf({ ...base, columns: many, rows: [Object.fromEntries(many.map((c) => [c.key, 'v']))] });
    expect(wide.orientation).toBe('landscape');
    expect(wide.document.html).toContain('size: A4 landscape');
    expect(wide.document.landscape).toBe(true);
  });
  it('lets cells wrap instead of clipping', () => {
    expect(buildReportPdf(base).document.html).toContain('overflow-wrap: break-word');
  });
  it('marks Urdu runs right-to-left so the shaper joins them', () => {
    expect(buildReportPdf(base).document.html).toContain('<span class="ur" dir="rtl" lang="ur">عائشہ احمد</span>');
  });
  it('collects every printed string for the glyph-coverage check', () => {
    expect(buildReportPdf(base).strings).toEqual(expect.arrayContaining(['عائشہ احمد', 'Seena School', 'Student']));
  });
  it('uses the letterhead when the campus has one', () => {
    const { document } = buildReportPdf({ ...base, branding: branding({ header_mode: 'letterhead' }), images: { letterheadDataUri: 'data:image/png;base64,LLLL', logoDataUri: 'data:image/png;base64,GGGG' } });
    expect(document.html).toContain('class="letterhead" src="data:image/png;base64,LLLL"');
  });
  it('substitutes the logo when there is no letterhead, keeping the identity text', () => {
    const { document } = buildReportPdf(base);
    expect(document.html).toContain('class="logo" src="data:image/png;base64,AAAA"');
    expect(document.html).toContain('12 Canal Road');
  });
  it('still lays out with no images at all', () => {
    const { document } = buildReportPdf({ ...base, branding: branding({ header_mode: 'none' }), images: { letterheadDataUri: null, logoDataUri: null } });
    expect(document.html).toContain('logo-empty');
    expect(document.html).toContain('Seena School');
  });
  it('escapes markup in data', () => {
    const { document } = buildReportPdf({ ...base, rows: [{ gr: '<script>x</script>', name: 'a', amt: 1 }] });
    expect(document.html).not.toContain('<script>x');
  });
});
