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

// FR-T05. The renderer never learns what a character certificate is — it
// substitutes whatever the snapshot froze — so what is worth pinning is that
// the field paths the SQL writes are the ones a character template names.
describe('a character certificate rendered from payload_snapshot', () => {
  const snapshot: CertificateSnapshot = {
    template: {
      id: 'tpl-cc-1',
      certificate_type: 'character',
      board_code: null,
      language: 'en',
      version: 1,
      status: 'issued',
      title: 'Character Certificate',
      body_html:
        '<p>Certified that {{student.name_en}}, GR {{student.gr_number}}, was a student of this school from ' +
        '{{character.period_from}} to {{character.period_to}} and that his conduct was ' +
        '{{character.conduct_grade}}. {{character.remarks}} Serial {{issue.serial_no}}.</p>',
      page_size: 'A4',
    },
    tenant: { name: 'Seena Model High School', name_ur: null },
    campus: { name: 'Main Campus', name_ur: null, code: 'MAIN', city: 'Lahore' },
    letterhead_storage_path: null,
    logo_storage_path: null,
    values: {
      'student.name_en': 'Ali Raza',
      'student.gr_number': '2018-0311',
      'character.period_from': '01-04-2018',
      'character.period_to': '31-03-2023',
      'character.conduct_grade': 'Excellent',
      'character.remarks': 'A diligent and courteous student.',
      'issue.serial_no': 'CC-2026-000001',
    },
  };

  const doc = () =>
    buildCertificateHtml(snapshotToPayload(snapshot), null, { letterheadDataUri: null, logoDataUri: null });

  it('AC1: prints the attendance period the issue derived, not today', () => {
    expect(doc().html).toContain('from 01-04-2018 to 31-03-2023');
  });

  it('AC2: prints the graded conduct', () => {
    expect(doc().html).toContain('his conduct was Excellent');
  });

  it('AC3: prints the serial from its own series', () => {
    expect(doc().html).toContain('Serial CC-2026-000001');
  });

  it('carries no PREVIEW watermark — an issued character certificate is the real document', () => {
    expect(doc().html).not.toContain('class="watermark"');
  });
});

// FR-T09. What the composited seal looks like in the document that is about
// to be handed to Chromium — the anchor arithmetic itself is
// lib/certificates/seal.test.ts.
describe('the signature and stamp composited onto an issued certificate', () => {
  const sealed = (): CertificatePreviewPayload => ({
    ...payload(),
    seal: {
      signing_identity_id: 'si-1',
      holder_name: 'Farhat Jabeen',
      designation: 'Principal',
      valid_from: '2026-01-01',
      valid_to: null,
      signature_storage_path: 't/c/signature/1.png',
      signature_width_px: 900,
      signature_height_px: 300,
      stamp_storage_path: 't/c/stamp/1.png',
      stamp_width_px: 800,
      stamp_height_px: 800,
      signature_anchor_x_mm: 140,
      signature_anchor_y_mm: 235,
      signature_width_mm: 45,
      stamp_anchor_x_mm: 35,
      stamp_anchor_y_mm: 232,
      stamp_width_mm: 35,
      stamp_opacity: 0.6,
    },
  });

  const assets = { letterheadDataUri: null, logoDataUri: null, signatureDataUri: 'data:image/png;base64,SIG', stampDataUri: 'data:image/png;base64,STAMP' };

  it('AC1: places the signature at the template anchor, converted into the page area', () => {
    const html = buildCertificateHtml(sealed(), null, assets).html;
    // (140mm, 235mm) on the page, less the 18mm/16mm @page margins.
    expect(html).toContain('class="seal-signature" src="data:image/png;base64,SIG"');
    expect(html).toContain('left:122mm;top:219mm;width:45mm;');
  });

  it('AC1: composites the stamp at 60% opacity', () => {
    expect(buildCertificateHtml(sealed(), null, assets).html).toContain('width:35mm;opacity:0.6;');
  });

  it('AC1: paints the seal behind the page content, so nothing it covers is obscured', () => {
    const html = buildCertificateHtml(sealed(), null, assets).html;
    expect(html).toContain('.seal-layer { position: fixed; inset: 0; z-index: 0; }');
    expect(html).toContain('.content { position: relative; z-index: 1; }');
    // …and the serial is part of that content, so it is painted on top.
    expect(html.indexOf('class="seal-layer"')).toBeLessThan(html.indexOf('class="content"'));
  });

  it('names the signatory and designation under the signature line', () => {
    const html = buildCertificateHtml(sealed(), null, assets).html;
    expect(html).toContain('<div class="signatory-name">Farhat Jabeen</div>');
    expect(html).toContain('<div class="signatory-name">Principal</div>');
  });

  it('prints the signature alone when the campus has a signature but no stamp', () => {
    const withoutStamp = sealed();
    withoutStamp.seal = { ...withoutStamp.seal!, stamp_storage_path: null, stamp_width_px: null, stamp_height_px: null };
    const html = buildCertificateHtml(withoutStamp, null, { ...assets, stampDataUri: null }).html;
    expect(html).toContain('class="seal-signature"');
    expect(html).not.toContain('class="seal-stamp"');
  });

  it('draws no seal layer at all for a campus with no signing identity', () => {
    const html = buildCertificateHtml(payload(), null, { letterheadDataUri: null, logoDataUri: null }).html;
    expect(html).not.toContain('<div class="seal-layer">');
    // The ruled lines FR-T01 printed are still there to sign by hand.
    expect(html).toContain('class="signatures"');
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
