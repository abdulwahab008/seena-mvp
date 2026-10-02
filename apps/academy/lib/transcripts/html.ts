import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';
import { escapeHtml } from '@/lib/challan/html';

/**
 * FR-J13: the printed cumulative transcript.
 *
 * Built from the register's payload_snapshot and nothing else, so a reprint of
 * an issued transcript is the document that was issued — the serial, the
 * issuing officer and the date are in the snapshot, not read from the clock or
 * from whoever happens to be printing.
 */
export type TranscriptSubject = {
  subject_name: string;
  weighted_pct: number | null;
  grade_label: string | null;
  is_pass: boolean | null;
};

export type TranscriptSession = {
  session_id: string;
  session_name: string;
  starts_on: string;
  ends_on: string;
  campus_name: string;
  class_name: string;
  section_name: string | null;
  status: 'complete' | 'incomplete' | 'withheld' | 'in_progress';
  note: string | null;
  left_on: string | null;
  terms_completed: string[];
  promotion_decision: string | null;
  aggregate_pct: number | null;
  subjects: TranscriptSubject[];
};

export type TranscriptSnapshot = {
  school: string | null;
  student: {
    name_en: string;
    name_ur: string | null;
    father_name_en: string | null;
    gr_number: string;
    dob: string | null;
    gender: string | null;
  };
  sessions: TranscriptSession[];
  serial_no?: string;
  issued_on?: string;
  issued_by_name?: string;
  issued_by_role?: string;
  purpose?: string;
};

const DECISION_LABEL: Record<string, string> = {
  promoted: 'Promoted',
  promoted_on_trial: 'Promoted on trial',
  compartment: 'Compartment',
  detained: 'Detained',
};

const ROLE_LABEL: Record<string, string> = {
  owner: 'Owner',
  super_admin: 'Administrator',
  principal: 'Principal',
  vice_principal: 'Vice Principal',
  exam_controller: 'Exam Controller',
};

export function collectTranscriptStrings(s: TranscriptSnapshot): (string | null)[] {
  return [
    s.school,
    s.student.name_en,
    s.student.name_ur,
    s.student.father_name_en,
    s.issued_by_name ?? null,
    ...s.sessions.flatMap((x) => [x.campus_name, x.class_name, ...x.subjects.map((sub) => sub.subject_name)]),
  ];
}

const fmtDate = (iso: string | null | undefined) =>
  iso
    ? new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' })
    : '—';

/** What the row says in the status column; the annotation text is the database's. */
export function sessionStatusText(x: TranscriptSession): string {
  if (x.status === 'withheld') return 'Withheld';
  if (x.status === 'incomplete') return x.note ?? 'Incomplete';
  if (x.status === 'in_progress') return 'In progress';
  const decision = x.promotion_decision ? DECISION_LABEL[x.promotion_decision] : null;
  return decision ?? 'Complete';
}

function sessionBlock(x: TranscriptSession): string {
  const subjects =
    x.status === 'withheld'
      ? '<p class="muted">Result withheld.</p>'
      : x.subjects.length > 0
        ? `<table class="subjects"><thead><tr><th>Subject</th><th class="num">%</th><th class="mid">Grade</th><th>Result</th></tr></thead><tbody>${x.subjects
            .map(
              (s) =>
                `<tr><td>${escapeHtml(s.subject_name)}</td><td class="num">${s.weighted_pct === null ? '—' : Number(s.weighted_pct).toFixed(2)}</td><td class="mid">${escapeHtml(s.grade_label ?? '—')}</td><td class="${s.is_pass === false ? 'fail' : ''}">${s.is_pass === null ? '' : s.is_pass ? 'Pass' : 'Fail'}</td></tr>`,
            )
            .join('')}</tbody></table>`
        : '';
  const terms =
    x.status !== 'withheld' && x.terms_completed.length > 0
      ? `<p class="muted">Terms completed: ${x.terms_completed.map(escapeHtml).join(', ')}</p>`
      : '';
  const aggregate =
    x.status !== 'withheld' && x.aggregate_pct !== null ? `<p class="muted">Aggregate ${Number(x.aggregate_pct).toFixed(2)}%</p>` : '';
  return `<section class="session" data-session="${escapeHtml(x.session_name)}" data-status="${x.status}">
  <h3><span>${escapeHtml(x.session_name)} — ${escapeHtml(x.class_name)}${x.section_name ? ` ${escapeHtml(x.section_name)}` : ''}</span><span class="status" data-session-status>${escapeHtml(sessionStatusText(x))}</span></h3>
  <p class="campus" data-campus>${escapeHtml(x.campus_name)}</p>
  ${terms}${subjects}${aggregate}
</section>`;
}

function css(font: ResolvedFont | null): string {
  return `${nastaliqFontFaceCss(font)}
@page { size: A4 portrait; margin: 14mm 16mm; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { font-family: 'Times New Roman', Times, Georgia, serif; font-size: 10pt; line-height: 1.35; color: #111; }
.urdu { font-family: '${NASTALIQ_FONT_FAMILY}', 'Noto Naskh Arabic', serif; direction: rtl; }
h1 { text-align: center; font-size: 16pt; margin: 0; }
.sub { text-align: center; font-size: 12pt; font-weight: 700; letter-spacing: 0.3mm; text-transform: uppercase; margin: 2mm 0 4mm; }
.meta { display: flex; justify-content: space-between; border-top: 0.4mm solid #111; border-bottom: 0.2mm solid #666; padding: 2mm 0; margin-bottom: 4mm; font-size: 9pt; }
.identity { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6mm 6mm; margin-bottom: 4mm; }
.identity .label { color: #444; display: inline-block; min-width: 26mm; }
.identity .value { font-weight: 700; }
.session { break-inside: avoid; border: 0.2mm solid #888; padding: 2mm 3mm; margin-bottom: 3mm; }
.session h3 { display: flex; justify-content: space-between; margin: 0; font-size: 11pt; }
.session .status { font-weight: 700; }
.session[data-status="withheld"] .status, .session[data-status="incomplete"] .status { color: #a00; }
.campus { margin: 0.5mm 0 1mm; font-size: 9pt; color: #333; }
.muted { margin: 1mm 0; font-size: 9pt; color: #444; }
table.subjects { width: 100%; border-collapse: collapse; margin-top: 1mm; }
table.subjects th, table.subjects td { border: 0.2mm solid #999; padding: 0.8mm 2mm; font-size: 9pt; text-align: left; }
table.subjects th { background: #eee; }
.num { text-align: right; } .mid { text-align: center; }
.fail { color: #a00; }
.signoff { margin-top: 8mm; display: flex; justify-content: space-between; align-items: flex-end; gap: 10mm; font-size: 9pt; }
.signoff div { flex: 1 1 0; }
.signoff .rule { border-top: 0.3mm solid #111; padding-top: 1mm; text-align: center; }
.footer { margin-top: 4mm; font-size: 8pt; color: #444; display: flex; justify-content: space-between; }`;
}

export function buildTranscriptHtml(s: TranscriptSnapshot, font: ResolvedFont | null): PrintDocument {
  const officer = s.issued_by_name ?? '';
  const role = s.issued_by_role ? (ROLE_LABEL[s.issued_by_role] ?? s.issued_by_role) : '';
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(`Transcript ${s.serial_no ?? ''} — ${s.student.name_en}`)}</title><style>${css(font)}</style></head><body>
<h1>${escapeHtml(s.school ?? '')}</h1>
<div class="sub">Cumulative Academic Transcript</div>
<div class="meta">
  <span>Serial No. <strong data-serial>${escapeHtml(s.serial_no ?? '')}</strong></span>
  <span>Date of issue <strong data-issued-on>${escapeHtml(fmtDate(s.issued_on))}</strong></span>
  <span>Purpose <strong>${escapeHtml(s.purpose ?? '')}</strong></span>
</div>
<div class="identity">
  <div><span class="label">Name</span><span class="value">${escapeHtml(s.student.name_en)}</span>${s.student.name_ur ? ` <span class="urdu">${escapeHtml(s.student.name_ur)}</span>` : ''}</div>
  <div><span class="label">GR No.</span><span class="value">${escapeHtml(s.student.gr_number)}</span></div>
  <div><span class="label">Father's name</span><span class="value">${escapeHtml(s.student.father_name_en ?? '—')}</span></div>
  <div><span class="label">Date of birth</span><span class="value">${escapeHtml(fmtDate(s.student.dob))}</span></div>
</div>
${s.sessions.map(sessionBlock).join('\n')}
<div class="signoff">
  <div class="rule" data-issued-by>${escapeHtml(officer)}${role ? `<br/>${escapeHtml(role)}` : ''}<br/>Issuing officer</div>
  <div class="rule">Seal</div>
</div>
<div class="footer"><span>${escapeHtml(s.serial_no ?? '')}</span><span>${s.sessions.length} session${s.sessions.length === 1 ? '' : 's'} on record</span></div>
</body></html>`;
  return { html, pageFormat: 'A4', landscape: false };
}
