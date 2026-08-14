import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';
import { escapeHtml } from '@/lib/certificates/merge';

/**
 * FR-J09: the printed report card.
 *
 * Shape mirrors lib/certificates/html.ts (FR-T01) and
 * lib/timetable-export/html.ts (FR-F15) — build one self-contained document
 * with every asset inlined as a data: URI, hand it to lib/pdf/render.ts —
 * because they share that renderer and there is no reason for a report card
 * to paginate or embed fonts differently.
 *
 * What is deliberately NOT here is a template engine. FR-T01's
 * certificate_template machinery substitutes merge fields into prose; a
 * report card is a table of N subject rows plus computed totals, and AC2
 * requires branding to come from campus branding with no per-report
 * configuration. See the migration header for the full argument.
 *
 * AC1's "a single A4 page" is a layout constraint, not a hope, so the type
 * scale and the row height are sized for a Pakistani school's usual eight to
 * twelve subjects and the sheet is checked for page count in the e2e run
 * rather than assumed.
 */

export type ReportCardSubject = {
  subject_name: string;
  subject_name_ur: string | null;
  obtained: number | null;
  max_marks: number | null;
  pct: number | null;
  grade_label: string | null;
  report_symbol: string | null;
  is_pass: boolean | null;
  failed_components: { component: string; obtained: number; pass_marks: number; max_marks: number }[];
};

export type ReportCardSnapshot = {
  school: {
    name: string;
    campus_name: string;
    campus_name_ur: string | null;
    campus_code: string;
    city: string | null;
    address_line: string | null;
    phone: string | null;
  } | null;
  branding: {
    logo_storage_path: string | null;
    letterhead_storage_path: string | null;
    signature_storage_path: string | null;
    stamp_storage_path: string | null;
  };
  student: {
    name_en: string;
    name_ur: string | null;
    father_name_en: string | null;
    father_name_ur: string | null;
    gr_number: string;
    roll_no: number | null;
    photo_path: string | null;
    class_name: string;
    section_name: string;
  };
  term: { exam_term_id: string; code: string; name: string; name_ur: string | null; session_name: string };
  subjects: ReportCardSubject[];
  aggregate: {
    obtained: number | null;
    max_marks: number | null;
    pct: number | null;
    grade_label: string | null;
    gpa_point: number | null;
    is_pass: boolean | null;
  };
  grading_scheme: { name: string; version: number; board: string } | null;
  position: {
    rank_in_section: number | null;
    ranked_out_of: number | null;
    rank_in_class: number | null;
    ranked_out_of_class: number | null;
    is_ranked: boolean;
    exclusion_reason: string | null;
  } | null;
  attendance: {
    months_counted: number;
    present_days: number;
    working_days: number;
    pct: number | null;
    from_date: string | null;
    to_date: string | null;
  };
  remark: string | null;
  revision_no: number;
  supersedes_revision: number | null;
  rendered_at: string;
};

export type ReportCardAssets = {
  letterheadDataUri: string | null;
  logoDataUri: string | null;
  signatureDataUri: string | null;
  stampDataUri: string | null;
  photoDataUri: string | null;
};

/** Everything on the page that could carry Arabic script, for the glyph check. */
export function collectReportCardStrings(snapshot: ReportCardSnapshot): (string | null)[] {
  return [
    snapshot.school?.name ?? '',
    snapshot.school?.campus_name ?? '',
    snapshot.school?.campus_name_ur ?? '',
    snapshot.student.name_en,
    snapshot.student.name_ur,
    snapshot.student.father_name_en,
    snapshot.student.father_name_ur,
    snapshot.term.name,
    snapshot.term.name_ur,
    snapshot.remark,
    ...snapshot.subjects.flatMap((s) => [s.subject_name, s.subject_name_ur]),
  ];
}

function fmtNum(value: number | null, dp = 0): string {
  return value === null || value === undefined ? '—' : Number(value).toFixed(dp);
}

/** AC1's "168 of 180 days (93.3%)" — one decimal place, as the AC writes it. */
export function attendanceLine(a: ReportCardSnapshot['attendance']): string {
  if (a.months_counted === 0 || a.working_days === 0) {
    return 'No attendance has been summarised for this session yet.';
  }
  return `${fmtNum(a.present_days, Number.isInteger(Number(a.present_days)) ? 0 : 1)} of ${a.working_days} days (${fmtNum(a.pct, 1)}%)`;
}

/**
 * The Notes' whole point: the summary is routinely short of the term's last
 * week, so the range it actually covers is printed beside the figure rather
 * than left for a parent to assume.
 */
export function attendanceRange(a: ReportCardSnapshot['attendance']): string {
  if (!a.from_date || !a.to_date) return '';
  const fmt = (iso: string) =>
    new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
      timeZone: 'UTC',
    });
  return `${fmt(a.from_date)} – ${fmt(a.to_date)}`;
}

/** AC1's "position 4 of 38", and FR-J05's dash-with-a-reason where there is none. */
export function positionLine(p: ReportCardSnapshot['position']): string {
  if (!p) return 'Not ranked yet';
  if (!p.is_ranked) {
    if (p.exclusion_reason === 'absent') return '— (absent in a paper)';
    if (p.exclusion_reason === 'withheld') return '— (result withheld)';
    return '—';
  }
  return `${p.rank_in_section} of ${p.ranked_out_of}`;
}

export function classPositionLine(p: ReportCardSnapshot['position']): string {
  if (!p || !p.is_ranked || p.rank_in_class === null) return '—';
  return `${p.rank_in_class} of ${p.ranked_out_of_class}`;
}

/** AC4's footer, and it reads off supersedes_revision rather than doing arithmetic. */
export function revisionFooter(snapshot: ReportCardSnapshot): string | null {
  if (snapshot.supersedes_revision === null) return null;
  return `Revised — supersedes revision ${snapshot.supersedes_revision}`;
}

function letterheadHtml(snapshot: ReportCardSnapshot, assets: ReportCardAssets): string {
  if (assets.letterheadDataUri) {
    return `<div class="letterhead"><img src="${assets.letterheadDataUri}" alt="" /></div>`;
  }
  const place = [snapshot.school?.campus_name, snapshot.school?.city].filter(Boolean).join(' · ');
  return `<div class="letterhead">
  ${assets.logoDataUri ? `<img class="logo" src="${assets.logoDataUri}" alt="" />` : ''}
  <div class="head-text">
    <div class="school">${escapeHtml(snapshot.school?.name ?? '')}</div>
    ${place ? `<div class="place">${escapeHtml(place)}</div>` : ''}
    ${snapshot.school?.address_line ? `<div class="place">${escapeHtml(snapshot.school.address_line)}</div>` : ''}
  </div>
</div>`;
}

function css(font: ResolvedFont | null): string {
  return `${nastaliqFontFaceCss(font)}
@page { size: A4 portrait; margin: 12mm 14mm; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: 'Times New Roman', Times, Georgia, serif;
  font-size: 10pt;
  line-height: 1.35;
  color: #111;
  -webkit-print-color-adjust: exact;
  print-color-adjust: exact;
}
.urdu { font-family: '${NASTALIQ_FONT_FAMILY}', 'Noto Naskh Arabic', serif; direction: rtl; line-height: 2.1; }
.letterhead { display: flex; align-items: center; gap: 6mm; border-bottom: 0.6mm solid #111; padding-bottom: 3mm; }
.letterhead img { max-width: 100%; }
.letterhead .logo { width: 18mm; height: 18mm; object-fit: contain; }
.letterhead .head-text { flex: 1 1 auto; text-align: center; }
.letterhead .school { font-size: 16pt; font-weight: 700; }
.letterhead .place { font-size: 9pt; color: #333; }
.doc-title { text-align: center; font-size: 12pt; font-weight: 700; letter-spacing: 0.3mm; margin: 4mm 0 3mm; text-transform: uppercase; }
.identity { display: flex; gap: 5mm; align-items: flex-start; margin-bottom: 3mm; }
.identity .fields { flex: 1 1 auto; display: grid; grid-template-columns: 1fr 1fr; gap: 0.6mm 5mm; }
.identity .photo { width: 25mm; height: 30mm; object-fit: cover; border: 0.2mm solid #666; }
.identity .photo-blank { width: 25mm; height: 30mm; border: 0.2mm dashed #999; }
.field { display: flex; gap: 2mm; }
.field .label { color: #444; min-width: 26mm; }
.field .value { font-weight: 700; }
table.marks { width: 100%; border-collapse: collapse; margin-top: 1mm; }
table.marks th, table.marks td { border: 0.2mm solid #666; padding: 1.1mm 2mm; }
table.marks th { background: #eee; font-size: 9pt; text-align: left; }
table.marks td.num, table.marks th.num { text-align: right; }
table.marks td.mid, table.marks th.mid { text-align: center; }
table.marks tr.total td { font-weight: 700; background: #f4f4f4; }
.fail { color: #a00; }
.summary { display: grid; grid-template-columns: 1fr 1fr; gap: 2mm 5mm; margin-top: 4mm; }
.panel { border: 0.2mm solid #666; padding: 2mm 3mm; }
.panel h3 { margin: 0 0 1mm; font-size: 9pt; text-transform: uppercase; letter-spacing: 0.2mm; color: #444; }
.panel .big { font-size: 12pt; font-weight: 700; }
.panel .note { font-size: 8pt; color: #444; }
.remark { margin-top: 4mm; border: 0.2mm solid #666; padding: 2mm 3mm; min-height: 14mm; }
.remark h3 { margin: 0 0 1mm; font-size: 9pt; text-transform: uppercase; letter-spacing: 0.2mm; color: #444; }
.signatures { margin-top: 8mm; display: flex; justify-content: space-between; gap: 10mm; align-items: flex-end; }
.signatures div { flex: 1 1 0; text-align: center; font-size: 9pt; }
.signatures .rule { border-top: 0.3mm solid #111; padding-top: 1mm; }
.signatures img { max-height: 14mm; max-width: 45mm; display: block; margin: 0 auto 1mm; }
.stamp { position: fixed; right: 16mm; bottom: 26mm; width: 32mm; opacity: 0.75; }
.footer { margin-top: 4mm; display: flex; justify-content: space-between; font-size: 8pt; color: #444; }
.revised { font-weight: 700; color: #a00; }`;
}

function subjectRow(s: ReportCardSubject): string {
  const failed = (s.failed_components ?? []).map((c) => c.component).join(', ');
  const marks = s.report_symbol
    ? `<td class="mid" colspan="2">${escapeHtml(s.report_symbol)}</td>`
    : `<td class="num">${fmtNum(s.obtained, 2)}</td><td class="num">${fmtNum(s.max_marks)}</td>`;
  return `<tr>
  <td>${escapeHtml(s.subject_name)}${s.subject_name_ur ? `<span class="urdu"> · ${escapeHtml(s.subject_name_ur)}</span>` : ''}</td>
  ${marks}
  <td class="num">${fmtNum(s.pct, 2)}</td>
  <td class="mid">${escapeHtml(s.grade_label ?? '—')}</td>
  <td class="${s.is_pass === false ? 'fail' : ''}">${
    s.is_pass === false ? escapeHtml(failed ? `Failed: ${failed}` : 'Failed') : ''
  }</td>
</tr>`;
}

export function buildReportCardHtml(
  snapshot: ReportCardSnapshot,
  font: ResolvedFont | null,
  assets: ReportCardAssets,
): PrintDocument {
  const { student, term, aggregate, attendance } = snapshot;
  const revised = revisionFooter(snapshot);
  const range = attendanceRange(attendance);

  const field = (label: string, value: string) =>
    `<div class="field"><span class="label">${escapeHtml(label)}</span><span class="value">${escapeHtml(value)}</span></div>`;

  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(
    `${student.name_en} — ${term.name}`,
  )}</title><style>${css(font)}</style></head><body>
${assets.stampDataUri ? `<img class="stamp" src="${assets.stampDataUri}" alt="" />` : ''}
${letterheadHtml(snapshot, assets)}
<h1 class="doc-title">Report Card — ${escapeHtml(term.name)} ${escapeHtml(term.session_name)}</h1>

<div class="identity">
  <div class="fields">
    ${field('Name', student.name_en)}
    ${field('GR No.', student.gr_number)}
    ${field("Father's name", student.father_name_en ?? '—')}
    ${field('Roll No.', student.roll_no === null ? '—' : String(student.roll_no))}
    ${field('Class', `${student.class_name} · ${student.section_name}`)}
    ${field('Session', term.session_name)}
  </div>
  ${
    assets.photoDataUri
      ? `<img class="photo" src="${assets.photoDataUri}" alt="" />`
      : '<div class="photo-blank"></div>'
  }
</div>

<table class="marks">
  <thead>
    <tr>
      <th>Subject</th>
      <th class="num">Obtained</th>
      <th class="num">Maximum</th>
      <th class="num">%</th>
      <th class="mid">Grade</th>
      <th>Remarks</th>
    </tr>
  </thead>
  <tbody>
    ${snapshot.subjects.map(subjectRow).join('\n')}
    <tr class="total">
      <td>Total</td>
      <td class="num" data-total-obtained>${fmtNum(aggregate.obtained, 2)}</td>
      <td class="num" data-total-max>${fmtNum(aggregate.max_marks)}</td>
      <td class="num" data-total-pct>${fmtNum(aggregate.pct, 2)}</td>
      <td class="mid" data-total-grade>${escapeHtml(aggregate.grade_label ?? '—')}</td>
      <td></td>
    </tr>
  </tbody>
</table>

<div class="summary">
  <div class="panel">
    <h3>Position in section</h3>
    <div class="big" data-position>${escapeHtml(positionLine(snapshot.position))}</div>
    <div class="note">In class: ${escapeHtml(classPositionLine(snapshot.position))}</div>
  </div>
  <div class="panel">
    <h3>Attendance</h3>
    <div class="big" data-attendance>${escapeHtml(attendanceLine(attendance))}</div>
    ${range ? `<div class="note" data-attendance-range>Covering ${escapeHtml(range)}</div>` : ''}
  </div>
</div>

<div class="remark">
  <h3>Class teacher&rsquo;s remark</h3>
  <div data-remark>${escapeHtml(snapshot.remark ?? '')}</div>
</div>

<div class="signatures">
  <div><div class="rule">Parent / Guardian</div></div>
  <div><div class="rule">Class teacher</div></div>
  <div>
    ${assets.signatureDataUri ? `<img src="${assets.signatureDataUri}" alt="" />` : ''}
    <div class="rule">Principal</div>
  </div>
</div>

<div class="footer">
  <span>${escapeHtml(
    snapshot.grading_scheme
      ? `Graded on ${snapshot.grading_scheme.name} v${snapshot.grading_scheme.version} (${snapshot.grading_scheme.board})`
      : '',
  )}</span>
  <span${revised ? ' class="revised" data-revision-note' : ''}>${escapeHtml(
    revised ?? `Revision ${snapshot.revision_no}`,
  )}</span>
</div>
</body></html>`;

  return { html, pageFormat: 'A4', landscape: false };
}
