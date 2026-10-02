import { describe, expect, it } from 'vitest';
import { buildCertificateDocument, certificateStrings, sanitizeTemplateHtml, type StaffCertificatePayload } from './document';
import { NASTALIQ_FONT_FAMILY, type ResolvedFont } from '@/lib/pdf/font';

const payload: StaffCertificatePayload = {
  certificate_no: 'EXP-2026-0043',
  cert_type: 'experience',
  title: 'Experience Certificate',
  body_html: '<p>This is to certify that <strong>{{staff_name}}</strong> served {{school_name}}, total service <strong>{{total_service}}</strong>.</p><script>alert(1)</script>',
  school_name: 'Bright Future School',
  school_name_ur: 'برائٹ فیوچر اسکول',
  spans: [
    { designation: 'Teacher', from: '2019-04-01', to: '2023-03-31', years: 4, months: 0 },
    { designation: 'Senior Teacher', from: '2023-04-01', to: '2026-08-31', years: 3, months: 5 },
  ],
  total_service: '7 years 5 months',
  values: { staff_name: 'Ayesha <Khan>', school_name: 'Bright Future School', total_service: '7 years 5 months' },
};

describe('staff certificate document (FR-D18)', () => {
  it('lists both designation spans and the total service', () => {
    const { html } = buildCertificateDocument(payload, null);
    expect(html).toContain('Teacher');
    expect(html).toContain('Senior Teacher');
    expect(html).toContain('01 Apr 2019');
    expect(html).toContain('31 Aug 2026');
    expect(html).toContain('7 years 5 months');
    expect(html).toContain('EXP-2026-0043');
  });

  it('escapes merged values and drops scripts from the template', () => {
    const { html } = buildCertificateDocument(payload, null);
    expect(html).toContain('Ayesha &lt;Khan&gt;');
    expect(html).not.toContain('<script');
    expect(html).not.toContain('alert(1)');
  });

  it('sets the Urdu school name in the embedded Nastaliq face', () => {
    const font: ResolvedFont = { path: '/tmp/fake.ttf', bytes: Buffer.from('\u0000\u0001\u0000\u0000fakefontbytes', 'latin1'), isCollection: false };
    const { html } = buildCertificateDocument(payload, font);
    expect(html).toContain('برائٹ فیوچر اسکول');
    expect(html).toContain(`@font-face { font-family: '${NASTALIQ_FONT_FAMILY}'`);
    expect(html).toContain('class="school-ur" lang="ur" dir="rtl"');
    expect(html).toContain(`font-family: '${NASTALIQ_FONT_FAMILY}'`);
  });

  it('hands the Urdu name to the glyph coverage check', () => {
    expect(certificateStrings(payload).join(' ')).toContain('برائٹ فیوچر اسکول');
  });

  it('leaves a missing merge value visible rather than silently blank', () => {
    const { html } = buildCertificateDocument({ ...payload, values: {} }, null);
    expect(html).toContain('[staff_name]');
  });
});

describe('template sanitising (FR-D18)', () => {
  it('keeps presentational tags and merge fields, removes everything else', () => {
    const dirty = '<p onclick="x()" style="color:red">Hi {{staff_name}}</p><img src="http://evil/x.png"><a href="http://evil">link</a><iframe src="x"></iframe><table><tr><td colspan="2">a</td></tr></table>';
    const clean = sanitizeTemplateHtml(dirty);
    expect(clean).toBe('<p>Hi {{staff_name}}</p>link<table><tr><td colspan="2">a</td></tr></table>');
  });

  it('removes style blocks and comments', () => {
    expect(sanitizeTemplateHtml('<style>body{display:none}</style><!-- x --><p>ok</p>')).toBe('<p>ok</p>');
  });
});
