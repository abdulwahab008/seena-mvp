import { describe, expect, it } from 'vitest';
import {
  buildCertificateHtml,
  collectCertificateStrings,
  snapshotToPayload,
  type CertificatePreviewPayload,
  type CertificateSnapshot,
} from './html';
import { NASTALIQ_FONT_FAMILY } from '@/lib/pdf/font';

function payload(over: Partial<CertificatePreviewPayload['template']> = {}): CertificatePreviewPayload {
  return {
    template: {
      id: 'tpl-1',
      certificate_type: 'transfer',
      board_code: 'FBISE',
      language: 'en',
      version: 3,
      status: 'active',
      title: 'School Leaving Certificate',
      body_html: '<p>{{student.name_en}} ({{student.gr_number}}) left on {{enrolment.left_on}}.</p>',
      page_size: 'A4',
      ...over,
    },
    tenant: { name: 'Seena Model High School', name_ur: 'سینا ماڈل ہائی اسکول' },
    campus: { name: 'Main Campus', name_ur: 'مرکزی کیمپس', code: 'MAIN', city: 'Lahore' },
    letterhead_storage_path: null,
    logo_storage_path: null,
    sample_values: {
      'student.name_en': 'Ahmed Raza',
      'student.gr_number': 'GR-001482',
      'enrolment.left_on': '31 July 2026',
    },
  };
}

describe('buildCertificateHtml', () => {
  it('substitutes the sample values into the authored wording', () => {
    const doc = buildCertificateHtml(payload(), null, { letterheadDataUri: null, logoDataUri: null });
    expect(doc.html).toContain('Ahmed Raza (GR-001482) left on 31 July 2026.');
  });

  it('prints the template title as the document heading', () => {
    expect(buildCertificateHtml(payload(), null, { letterheadDataUri: null, logoDataUri: null }).html).toContain(
      '<h1 class="doc-title">School Leaving Certificate</h1>',
    );
  });

  it('carries the stored page size into the @page rule and the document', () => {
    const a5 = buildCertificateHtml(payload({ page_size: 'A5' }), null, { letterheadDataUri: null, logoDataUri: null });
    expect(a5.pageFormat).toBe('A5');
    expect(a5.html).toContain('@page { size: A5 portrait;');
    const legal = buildCertificateHtml(payload({ page_size: 'Legal' }), null, { letterheadDataUri: null, logoDataUri: null });
    expect(legal.html).toContain('@page { size: legal portrait;');
  });

  it('AC4: an Urdu template is right-to-left and asks for the Nastaliq face', () => {
    const doc = buildCertificateHtml(payload({ language: 'ur' }), null, { letterheadDataUri: null, logoDataUri: null });
    expect(doc.html).toContain('<html lang="ur" dir="rtl">');
    expect(doc.html).toContain('direction: rtl');
    expect(doc.html).toContain(`font-family: '${NASTALIQ_FONT_FAMILY}'`);
  });

  it('AC4: an Urdu template prints the Urdu school name on the letterhead', () => {
    const doc = buildCertificateHtml(payload({ language: 'ur' }), null, { letterheadDataUri: null, logoDataUri: null });
    expect(doc.html).toContain('سینا ماڈل ہائی اسکول');
    expect(doc.html).toContain('مرکزی کیمپس');
  });

  it('keeps an English template left-to-right', () => {
    const doc = buildCertificateHtml(payload(), null, { letterheadDataUri: null, logoDataUri: null });
    expect(doc.html).toContain('<html lang="en" dir="ltr">');
    expect(doc.html).toContain('Seena Model High School');
  });

  it('uses the uploaded letterhead image instead of the text header when there is one', () => {
    const doc = buildCertificateHtml(payload(), null, {
      letterheadDataUri: 'data:image/png;base64,AAAA',
      logoDataUri: 'data:image/png;base64,BBBB',
    });
    expect(doc.html).toContain('<img src="data:image/png;base64,AAAA"');
    expect(doc.html).not.toContain('letterhead-text');
  });

  it('marks a draft preview as a draft, so it cannot pass for an issued document', () => {
    const draft = buildCertificateHtml(payload({ status: 'draft', version: 4 }), null, {
      letterheadDataUri: null,
      logoDataUri: null,
    });
    expect(draft.html).toContain('DRAFT v4 — PREVIEW');
  });

  it('escapes tenant data that arrives with markup in it', () => {
    const p = payload();
    p.tenant = { name: 'A & B <School>', name_ur: null };
    expect(buildCertificateHtml(p, null, { letterheadDataUri: null, logoDataUri: null }).html).toContain(
      'A &amp; B &lt;School&gt;',
    );
  });
});

// FR-T03. The snapshot is what an issued certificate reprints from; these
// are the properties that make "no previously issued certificate ever
// re-renders against a later template version" true rather than aspirational.
describe('an issued certificate rendered from payload_snapshot', () => {
  const snapshot: CertificateSnapshot = {
    template: {
      id: 'tpl-v1',
      certificate_type: 'transfer',
      board_code: 'FBISE',
      language: 'en',
      version: 1,
      status: 'issued',
      title: 'School Leaving Certificate',
      body_html:
        '<p>{{student.name_en}}, GR {{student.gr_number}}, born {{student.dob}} ({{student.dob_words}}), ' +
        'left on {{enrolment.left_on}}. Conduct {{transfer.conduct}}. Dues {{transfer.dues_cleared}}. ' +
        'Serial {{issue.serial_no}}.</p>',
      page_size: 'A4',
    },
    tenant: { name: 'Seena Model High School', name_ur: 'سینا ماڈل ہائی اسکول' },
    campus: { name: 'Main Campus', name_ur: 'مرکزی کیمپس', code: 'MAIN', city: 'Lahore' },
    letterhead_storage_path: null,
    logo_storage_path: null,
    values: {
      'student.name_en': 'Ali Raza',
      'student.gr_number': '2019-0442',
      'student.dob': '04-03-2011',
      'student.dob_words': 'Fourth March Two Thousand Eleven',
      'enrolment.left_on': '30-06-2026',
      'transfer.conduct': 'Good',
      'transfer.dues_cleared': null,
      'issue.serial_no': 'TC-2026-000147',
    },
  };

  const doc = () =>
    buildCertificateHtml(snapshotToPayload(snapshot), null, { letterheadDataUri: null, logoDataUri: null });

  it('AC3: prints the date of birth in figures and in words', () => {
    expect(doc().html).toContain('born 04-03-2011 (Fourth March Two Thousand Eleven)');
  });

  it('prints the frozen serial, GR number and leaving date', () => {
    const html = doc().html;
    expect(html).toContain('Ali Raza, GR 2019-0442');
    expect(html).toContain('left on 30-06-2026');
    expect(html).toContain('Serial TC-2026-000147');
  });

  it('carries no PREVIEW or DRAFT watermark — this one is the real document', () => {
    const html = doc().html;
    expect(html).not.toContain('PREVIEW');
    expect(html).not.toContain('class="watermark"');
  });

  it('renders the wording the snapshot froze, not whatever the template says now', () => {
    // The same template has since forked to v2 with different wording; the
    // snapshot is the only input, so the reprint cannot see it.
    expect(doc().html).toContain('School Leaving Certificate');
    expect(doc().html).toContain('left on 30-06-2026. Conduct Good.');
  });

  it('leaves a deliberately blank field visibly blank rather than silently empty', () => {
    // transfer.dues_cleared is null because the fee module has not answered
    // it; a visible gap on a statutory page beats a sentence that reads as
    // though the dues were cleared.
    expect(doc().html).toContain('Dues [transfer.dues_cleared]');
  });
});

describe('collectCertificateStrings', () => {
  it('includes the merged body, so an Urdu value in an English template is still glyph-checked', () => {
    const p = payload();
    p.sample_values['student.name_en'] = 'احمد رضا';
    expect(collectCertificateStrings(p).join(' ')).toContain('احمد رضا');
  });

  it('includes the school and campus names in both scripts', () => {
    const joined = collectCertificateStrings(payload()).join(' ');
    expect(joined).toContain('سینا ماڈل ہائی اسکول');
    expect(joined).toContain('مرکزی کیمپس');
  });
});
