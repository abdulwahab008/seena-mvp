import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from '@/lib/pdf/font';
import type { PageFormat, PrintDocument } from '@/lib/pdf/render';
import { applyMergeFields, escapeHtml } from './merge';

/**
 * FR-T01: the printed certificate itself. Shape mirrors
 * lib/timetable-export/html.ts (FR-F15) — build one self-contained
 * document, hand it to lib/pdf/render.ts — because they now share that
 * renderer and there is no reason for a certificate to paginate or embed
 * fonts differently from a timetable sheet.
 *
 * AC4 is the reason the Urdu path is not an afterthought: an `ur` template
 * gets `dir="rtl"` on the document (so paragraph direction, list markers
 * and punctuation placement are right-to-left, not just visually mirrored
 * text), the Nastaliq face inlined as a data: URI so the PDF embeds the
 * exact bytes the coverage check validated, and a line-height Nastaliq
 * actually needs — its descending kerns clip at normal leading.
 */

export type CertificateLanguage = 'en' | 'ur';

export type CertificatePreviewPayload = {
  template: {
    id: string;
    certificate_type: string;
    board_code: string | null;
    language: CertificateLanguage;
    version: number;
    status: string;
    title: string;
    body_html: string;
    page_size: PageFormat;
  };
  tenant: { name: string; name_ur: string | null } | null;
  campus: { name: string; name_ur: string | null; code: string; city: string | null } | null;
  letterhead_storage_path: string | null;
  logo_storage_path: string | null;
  sample_values: Record<string, string | null>;
};

export type CertificateAssets = { letterheadDataUri: string | null; logoDataUri: string | null };

/**
 * FR-T03: what issue_transfer_certificate() freezes onto
 * certificate_issue.payload_snapshot. Same shape as a preview payload
 * except that the values are the resolved, frozen ones rather than the
 * catalogue's samples — which is the whole point of the snapshot: an
 * issued certificate reprints from the wording and the values it was
 * issued with, never from whatever the template says today.
 */
export type CertificateSnapshot = Omit<CertificatePreviewPayload, 'sample_values'> & {
  values: Record<string, string | null>;
};

export function snapshotToPayload(snapshot: CertificateSnapshot): CertificatePreviewPayload {
  const { values, ...rest } = snapshot;
  return { ...rest, sample_values: values };
}

/** CSS `@page size` keyword for each stored page size. */
const PAGE_SIZE_KEYWORD: Record<PageFormat, string> = { A3: 'A3', A4: 'A4', A5: 'A5', Legal: 'legal' };

/**
 * Everything on the page that could contain Arabic script, for the glyph
 * coverage check. The merged body is included rather than the raw
 * template, so an Urdu sample value in an otherwise English template is
 * still checked.
 */
export function collectCertificateStrings(payload: CertificatePreviewPayload): (string | null)[] {
  return [
    payload.template.title,
    applyMergeFields(payload.template.body_html, payload.sample_values),
    payload.tenant?.name ?? '',
    payload.tenant?.name_ur ?? '',
    payload.campus?.name ?? '',
    payload.campus?.name_ur ?? '',
    ...Object.values(payload.sample_values),
  ];
}

function letterheadHtml(payload: CertificatePreviewPayload, assets: CertificateAssets): string {
  if (assets.letterheadDataUri) {
    return `<div class="letterhead"><img src="${assets.letterheadDataUri}" alt="" /></div>`;
  }
  const { tenant, campus, template } = payload;
  const schoolName = template.language === 'ur' && tenant?.name_ur ? tenant.name_ur : (tenant?.name ?? '');
  const campusName = template.language === 'ur' && campus?.name_ur ? campus.name_ur : (campus?.name ?? '');
  const place = [campusName, campus?.city].filter(Boolean).join(' · ');
  return `<div class="letterhead letterhead-text">
  ${assets.logoDataUri ? `<img class="logo" src="${assets.logoDataUri}" alt="" />` : ''}
  <div class="school">${escapeHtml(schoolName)}</div>
  ${place ? `<div class="place">${escapeHtml(place)}</div>` : ''}
</div>`;
}

function css(payload: CertificatePreviewPayload, font: ResolvedFont | null): string {
  const rtl = payload.template.language === 'ur';
  const bodyFont = rtl
    ? `'${NASTALIQ_FONT_FAMILY}', 'Noto Naskh Arabic', serif`
    : `'Times New Roman', Times, Georgia, serif`;
  return `${nastaliqFontFaceCss(font)}
@page { size: ${PAGE_SIZE_KEYWORD[payload.template.page_size]} portrait; margin: 16mm 18mm; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: ${bodyFont};
  font-size: ${rtl ? '13pt' : '12pt'};
  line-height: ${rtl ? '2.4' : '1.7'};
  color: #111;
  direction: ${rtl ? 'rtl' : 'ltr'};
  text-align: ${rtl ? 'right' : 'left'};
  -webkit-print-color-adjust: exact;
  print-color-adjust: exact;
}
.letterhead { text-align: center; border-bottom: 0.6mm solid #111; padding-bottom: 4mm; margin-bottom: 6mm; }
.letterhead img { max-width: 100%; }
.letterhead .logo { width: 20mm; height: 20mm; object-fit: contain; display: block; margin: 0 auto 2mm; }
.letterhead .school { font-size: 18pt; font-weight: 700; line-height: 1.6; }
.letterhead .place { font-size: 10pt; color: #333; }
.doc-title { text-align: center; font-size: 15pt; font-weight: 700; letter-spacing: 0.4mm; margin: 0 0 6mm; text-decoration: underline; }
.body p { margin: 0 0 4mm; }
.body table { width: 100%; border-collapse: collapse; }
.body th, .body td { border: 0.2mm solid #666; padding: 1.5mm 2mm; text-align: ${rtl ? 'right' : 'left'}; }
.signatures { margin-top: 18mm; display: flex; justify-content: space-between; gap: 10mm; }
.signatures div { flex: 1 1 0; border-top: 0.3mm solid #111; padding-top: 2mm; font-size: 10pt; text-align: center; }
.watermark { position: fixed; top: 45%; left: 0; right: 0; text-align: center; font-size: 46pt; color: rgba(0,0,0,0.08); letter-spacing: 3mm; }`;
}

export function buildCertificateHtml(
  payload: CertificatePreviewPayload,
  font: ResolvedFont | null,
  assets: CertificateAssets,
): PrintDocument {
  const { template } = payload;
  const rtl = template.language === 'ur';
  const body = applyMergeFields(template.body_html, payload.sample_values);
  const signatoryLabel = rtl ? 'دستخط' : 'Signature';
  const stampLabel = rtl ? 'مہر' : 'School stamp';

  // A preview is never an issued document; saying so on the page itself is
  // what stops one being handed over a counter. FR-T03's snapshot carries
  // status 'issued' — a value certificate_template_status cannot hold — so
  // the real thing prints with no watermark at all, and nothing else had to
  // change to let it.
  const watermark =
    template.status === 'issued' ? null : template.status === 'active' ? 'PREVIEW' : `DRAFT v${template.version} — PREVIEW`;

  const html = `<!doctype html><html lang="${rtl ? 'ur' : 'en'}" dir="${rtl ? 'rtl' : 'ltr'}"><head><meta charset="utf-8"><title>${escapeHtml(template.title)}</title><style>${css(payload, font)}</style></head><body>
${watermark ? `<div class="watermark">${escapeHtml(watermark)}</div>` : ''}
${letterheadHtml(payload, assets)}
<h1 class="doc-title">${escapeHtml(template.title)}</h1>
<div class="body">${body}</div>
<div class="signatures"><div>${escapeHtml(stampLabel)}</div><div>${escapeHtml(signatoryLabel)}</div></div>
</body></html>`;

  return { html, pageFormat: template.page_size, landscape: false };
}
