import { applyMergeFields, escapeHtml } from '@/lib/certificates/merge';
import { buildHrDocumentHtml, collectHrDocumentStrings, type HrDocumentInput } from '@/lib/hr/print';
import type { ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';

/**
 * FR-D18: the printed staff certificate. Everything it says comes from the payload snapshot stored
 * when the certificate was issued (wording, names, designation spans, total service), never from the
 * template or the designation history as they are today, so a reprint reproduces what was signed.
 */
export type CertificateSpan = { designation: string; from: string; to: string; years: number; months: number };
export type StaffCertificatePayload = {
  certificate_no: string;
  cert_type: 'experience' | 'service' | 'noc';
  title: string;
  body_html: string;
  school_name: string;
  school_name_ur: string | null;
  spans: CertificateSpan[];
  total_service: string;
  values: Record<string, string | null>;
};

const ALLOWED_TAGS = new Set(['p', 'br', 'strong', 'b', 'em', 'i', 'u', 'ul', 'ol', 'li', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'h2', 'h3', 'h4', 'span', 'div', 'hr', 'blockquote']);
const KEPT_ATTRS = new Set(['colspan', 'rowspan']);

/**
 * The template is authored by school staff and rendered by a headless browser, so it is reduced to a
 * small allow-list of presentational tags with no scripts, styles, links, images or event handlers
 * before it is ever merged or printed. Merge placeholders ({{field}}) pass through untouched.
 */
export function sanitizeTemplateHtml(html: string): string {
  const withoutBlocks = html
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<(script|style|iframe|object|embed|link|meta|svg|math|form|noscript)\b[\s\S]*?(<\/\1\s*>|$)/gi, '');
  return withoutBlocks.replace(/<\s*(\/?)\s*([a-zA-Z][a-zA-Z0-9]*)([^>]*)>/g, (_m, slash: string, tag: string, attrs: string) => {
    const name = tag.toLowerCase();
    if (!ALLOWED_TAGS.has(name)) return '';
    if (slash) return `</${name}>`;
    const kept: string[] = [];
    for (const m of attrs.matchAll(/([a-zA-Z-]+)\s*=\s*"(\d{1,2})"/g)) {
      if (KEPT_ATTRS.has(m[1]!.toLowerCase())) kept.push(`${m[1]!.toLowerCase()}="${m[2]}"`);
    }
    return `<${name}${kept.length ? ' ' + kept.join(' ') : ''}${name === 'br' || name === 'hr' ? ' /' : ''}>`;
  });
}

function fmtDate(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', timeZone: 'UTC' });
}

function duration(years: number, months: number): string {
  const y = years > 0 ? `${years} year${years === 1 ? '' : 's'}` : '';
  const m = months > 0 ? `${months} month${months === 1 ? '' : 's'}` : '';
  return [y, m].filter(Boolean).join(' ') || 'less than a month';
}

export function certificateDocumentInput(p: StaffCertificatePayload): HrDocumentInput {
  const body = applyMergeFields(sanitizeTemplateHtml(p.body_html), p.values);
  const spans =
    p.spans.length > 0
      ? `<table class="lines"><thead><tr><th>Position</th><th>From</th><th>To</th><th class="num">Period</th></tr></thead><tbody>
${p.spans.map((s) => `<tr><td>${escapeHtml(s.designation)}</td><td>${escapeHtml(fmtDate(s.from))}</td><td>${escapeHtml(fmtDate(s.to))}</td><td class="num">${escapeHtml(duration(s.years, s.months))}</td></tr>`).join('\n')}
<tr class="total"><td colspan="3">Total service</td><td class="num">${escapeHtml(p.total_service)}</td></tr></tbody></table>`
      : '';
  return {
    title: p.title,
    schoolName: p.school_name,
    schoolNameUr: p.school_name_ur,
    bodyHtml: `${body}${spans}<div class="signatures"><div>School stamp</div><div>Principal</div></div>`,
    footerHtml: `Certificate No. ${escapeHtml(p.certificate_no)}`,
  };
}

export function buildCertificateDocument(p: StaffCertificatePayload, font: ResolvedFont | null): PrintDocument {
  return buildHrDocumentHtml(certificateDocumentInput(p), font);
}

/** Every string that could contain Arabic script, for the glyph-coverage check before rendering. */
export function certificateStrings(p: StaffCertificatePayload): string[] {
  return [...collectHrDocumentStrings(certificateDocumentInput(p)), ...Object.values(p.values).map((v) => v ?? '')];
}
