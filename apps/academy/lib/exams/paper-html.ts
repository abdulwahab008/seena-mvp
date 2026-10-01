import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';

/**
 * FR-I07. The printed question paper and its answer key. Both carry the set
 * code in the header AND the footer, and the key's heading repeats it, so a Set B
 * paper filed with the Set A key is visible on the page as well as at the
 * storage path. The filename carries the set code too.
 */
export type PaperPrintItem = {
  section_no: number;
  question_no: number;
  question_type: string;
  marks: number;
  question_text: string;
  options: string[] | null;
  answer: string | null;
};

export type PaperPrintSection = { no: number; name: string; type: string; count: number; marks_each: number };

export type PaperPrintPayload = {
  schoolName: string;
  className: string;
  subjectNameEn: string;
  subjectNameUr: string | null;
  termName: string;
  setCode: string;
  setCount: number;
  totalMarks: number;
  sections: PaperPrintSection[];
  items: PaperPrintItem[];
};

function esc(value: string | null | undefined): string {
  if (value === null || value === undefined) return '';
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'paper';

/** question-paper-physics-set-b.pdf / answer-key-physics-set-b.pdf */
export function paperFileName(kind: 'paper' | 'key', subjectNameEn: string, setCode: string): string {
  return `${kind === 'key' ? 'answer-key' : 'question-paper'}-${slug(subjectNameEn)}-set-${setCode.toLowerCase()}.pdf`;
}

export function collectPaperStrings(p: PaperPrintPayload): (string | null)[] {
  return [p.subjectNameUr, p.subjectNameEn, p.schoolName, ...p.items.flatMap((i): (string | null)[] => [i.question_text, ...(i.options ?? [])])];
}

const baseCss = (font: ResolvedFont | null) => `${nastaliqFontFaceCss(font)}
@page { size: A4 portrait; margin: 14mm; }
* { box-sizing: border-box; }
body { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; color: #111; font-size: 10.5pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
header { border-bottom: 0.6mm solid #111; padding-bottom: 2mm; margin-bottom: 4mm; display: flex; justify-content: space-between; align-items: flex-start; }
header h1 { font-size: 14pt; margin: 0; }
.meta { font-size: 9pt; color: #333; }
.setcode { font-size: 22pt; font-weight: 800; border: 0.6mm solid #111; padding: 0 5mm; }
h2 { font-size: 11pt; margin: 5mm 0 2mm; }
.q { margin: 0 0 2.5mm; break-inside: avoid; }
.marks { float: right; color: #444; }
ol.opts { margin: 1mm 0 0 6mm; padding: 0; list-style: upper-alpha; }
footer { margin-top: 6mm; border-top: 0.2mm solid #999; padding-top: 1.5mm; font-size: 8.5pt; color: #444; display: flex; justify-content: space-between; }
.ur { font-family: '${NASTALIQ_FONT_FAMILY}', serif; direction: rtl; unicode-bidi: isolate; line-height: 1.9; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 0.2mm solid #999; padding: 1mm 2mm; text-align: left; }
th { background: #eee; }`;

function headerHtml(p: PaperPrintPayload, title: string): string {
  return `<header>
  <div>
    <h1>${esc(p.schoolName)}</h1>
    <div class="meta">${esc(p.className)} · ${esc(p.subjectNameEn)} <span class="ur">${esc(p.subjectNameUr)}</span> · ${esc(p.termName)} · ${p.totalMarks} marks</div>
    <div class="meta"><strong>${esc(title)}</strong></div>
  </div>
  <div class="setcode" data-set="${esc(p.setCode)}">${p.setCount > 1 ? `SET ${esc(p.setCode)}` : esc(p.setCode)}</div>
</header>`;
}

const footerHtml = (p: PaperPrintPayload, what: string) => `<footer><span>${esc(what)} · Set ${esc(p.setCode)}</span><span>${esc(p.subjectNameEn)} · ${esc(p.className)}</span></footer>`;

export function buildQuestionPaperHtml(p: PaperPrintPayload, font: ResolvedFont | null): PrintDocument {
  const body = p.sections
    .map((s) => {
      const items = p.items.filter((i) => i.section_no === s.no).sort((a, b) => a.question_no - b.question_no);
      const qs = items
        .map(
          (i) => `<div class="q"><span class="marks">[${i.marks}]</span><strong>Q${i.question_no}.</strong> ${esc(i.question_text)}${
            i.options && i.options.length > 0 ? `<ol class="opts">${i.options.map((o) => `<li>${esc(o)}</li>`).join('')}</ol>` : ''
          }</div>`,
        )
        .join('\n');
      return `<section><h2>${esc(s.name)} — ${s.count} × ${s.marks_each} = ${s.count * s.marks_each} marks</h2>${qs}</section>`;
    })
    .join('\n');
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Question paper — Set ${esc(p.setCode)}</title><style>${baseCss(font)}</style></head><body>
${headerHtml(p, 'Question paper')}
${body}
${footerHtml(p, 'Question paper')}
</body></html>`;
  return { html, pageFormat: 'A4', landscape: false };
}

export function buildAnswerKeyHtml(p: PaperPrintPayload, font: ResolvedFont | null): PrintDocument {
  const sections = p.sections
    .map((s) => {
      const items = p.items.filter((i) => i.section_no === s.no).sort((a, b) => a.question_no - b.question_no);
      const rows = items.map((i) => `<tr><td>Q${i.question_no}</td><td>${i.marks}</td><td>${esc(i.answer) || '—'}</td></tr>`).join('');
      return `<section><h2>${esc(s.name)}</h2><table><thead><tr><th>Question</th><th>Marks</th><th>Answer</th></tr></thead><tbody>${rows}</tbody></table></section>`;
    })
    .join('\n');
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Answer key — Set ${esc(p.setCode)}</title><style>${baseCss(font)}</style></head><body>
${headerHtml(p, `ANSWER KEY — SET ${p.setCode}`)}
${sections}
${footerHtml(p, 'Answer key')}
</body></html>`;
  return { html, pageFormat: 'A4', landscape: false };
}
