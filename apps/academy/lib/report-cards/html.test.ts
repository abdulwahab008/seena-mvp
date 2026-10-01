import { describe, expect, it } from 'vitest';
import {
  attendanceLine,
  attendanceRange,
  buildMergedReportCardHtml,
  buildReportCardHtml,
  classPositionLine,
  collectReportCardStrings,
  positionLine,
  promotionLine,
  revisionFooter,
  type ReportCardSnapshot,
} from './html';

/**
 * FR-J09. The card's sentences, tested away from the renderer: AC1's
 * "168 of 180 days (93.3%)", AC4's "Revised — supersedes revision 1", and
 * FR-J05's dash-with-a-reason where there is no position. Each of them is a
 * place where a blank or a zero would be read as a fact.
 */
const snapshot = (over: Partial<ReportCardSnapshot> = {}): ReportCardSnapshot => ({
  school: {
    name: 'Seena Public School',
    campus_name: 'Main Campus',
    campus_name_ur: null,
    campus_code: 'MAIN',
    city: 'Lahore',
    address_line: '12 Ferozepur Road',
    phone: null,
  },
  branding: {
    logo_storage_path: null,
    letterhead_storage_path: null,
    signature_storage_path: null,
    stamp_storage_path: null,
  },
  student: {
    name_en: 'Ayesha Noor',
    name_ur: 'عائشہ نور',
    father_name_en: 'Muhammad Noor',
    father_name_ur: null,
    gr_number: 'MAIN-000001',
    roll_no: 4,
    photo_path: null,
    class_name: 'Class 5',
    section_name: 'A',
  },
  term: { exam_term_id: 't1', code: 'FINAL', name: 'Final Term', name_ur: null, session_name: '2026-27' },
  subjects: [
    {
      subject_name: 'English',
      subject_name_ur: 'انگریزی',
      obtained: 76,
      max_marks: 100,
      pct: 76,
      grade_label: 'A',
      report_symbol: null,
      is_pass: true,
      failed_components: [],
    },
  ],
  aggregate: { obtained: 612, max_marks: 800, pct: 76.5, grade_label: 'A', gpa_point: 3.7, is_pass: true },
  grading_scheme: { name: 'FBISE 2025', version: 1, board: 'FBISE' },
  position: {
    rank_in_section: 4,
    ranked_out_of: 38,
    rank_in_class: 9,
    ranked_out_of_class: 112,
    is_ranked: true,
    exclusion_reason: null,
  },
  attendance: {
    months_counted: 2,
    present_days: 168,
    working_days: 180,
    pct: 93.33,
    from_date: '2026-04-01',
    to_date: '2026-05-31',
  },
  remark: 'A steady term.',
  revision_no: 1,
  supersedes_revision: null,
  rendered_at: '2026-06-30T09:05:07.000Z',
  ...over,
});

const noAssets = {
  letterheadDataUri: null,
  logoDataUri: null,
  signatureDataUri: null,
  stampDataUri: null,
  photoDataUri: null,
};

describe('attendance', () => {
  it('AC1: reads "168 of 180 days (93.3%)" — one decimal, as the criterion writes it', () => {
    expect(attendanceLine(snapshot().attendance)).toBe('168 of 180 days (93.3%)');
  });

  it('prints the range the summary actually covers, which is the whole of the FR Notes', () => {
    expect(attendanceRange(snapshot().attendance)).toBe('1 Apr 2026 – 31 May 2026');
  });

  it('says nothing has been summarised rather than reporting 0%', () => {
    const a = { months_counted: 0, present_days: 0, working_days: 0, pct: null, from_date: null, to_date: null };
    expect(attendanceLine(a)).toBe('N/A');
    expect(attendanceRange(a)).toBe('');
  });

  it('keeps a half day visible rather than rounding it into a whole one', () => {
    const a = { ...snapshot().attendance, present_days: 167.5, pct: 93.06 };
    expect(attendanceLine(a)).toBe('167.5 of 180 days (93.1%)');
  });
});

describe('position', () => {
  it('AC1: "4 of 38"', () => {
    expect(positionLine(snapshot().position)).toBe('4 of 38');
    expect(classPositionLine(snapshot().position)).toBe('9 of 112');
  });

  it('FR-J05: a dash with the reason beside it, never a blank', () => {
    const absent = { ...snapshot().position!, is_ranked: false, exclusion_reason: 'absent', rank_in_section: null };
    expect(positionLine(absent)).toBe('— (absent in a paper)');
    const withheld = { ...absent, exclusion_reason: 'withheld' };
    expect(positionLine(withheld)).toBe('— (result withheld)');
  });

  it('distinguishes "not ranked yet" from "not ranked" — a missing row is a different fact', () => {
    expect(positionLine(null)).toBe('Not ranked yet');
    expect(classPositionLine(null)).toBe('—');
  });
});

describe('revision footer', () => {
  it('AC4: reads "Revised — supersedes revision 1"', () => {
    expect(revisionFooter(snapshot({ revision_no: 2, supersedes_revision: 1 }))).toBe(
      'Revised — supersedes revision 1',
    );
  });

  it('says nothing on a first issue', () => {
    expect(revisionFooter(snapshot())).toBeNull();
  });

  it('names the revision it really supersedes, not revision_no - 1', () => {
    // Revision 2 was reserved and voided, so revision 3 supersedes revision 1.
    expect(revisionFooter(snapshot({ revision_no: 3, supersedes_revision: 1 }))).toBe(
      'Revised — supersedes revision 1',
    );
  });
});

describe('the document', () => {
  it('is A4 portrait, because AC1 asks for a single A4 page', () => {
    const doc = buildReportCardHtml(snapshot(), null, noAssets);
    expect(doc.pageFormat).toBe('A4');
    expect(doc.landscape).toBe(false);
    expect(doc.html).toContain('@page { size: A4 portrait;');
  });

  it('carries AC1 s figures and the frozen scale it was graded on', () => {
    const html = buildReportCardHtml(snapshot(), null, noAssets).html;
    expect(html).toContain('612.00');
    expect(html).toContain('76.50');
    expect(html).toContain('168 of 180 days (93.3%)');
    expect(html).toContain('Covering 1 Apr 2026 – 31 May 2026');
    expect(html).toContain('Graded on FBISE 2025 v1 (FBISE)');
  });

  it('escapes a name that contains markup rather than rendering it', () => {
    const html = buildReportCardHtml(
      snapshot({ remark: '<script>alert(1)</script>' }),
      null,
      noAssets,
    ).html;
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain('&lt;script&gt;');
  });

  it('falls back to a text letterhead when the campus has uploaded nothing', () => {
    const html = buildReportCardHtml(snapshot(), null, noAssets).html;
    expect(html).toContain('Seena Public School');
    expect(html).toContain('Main Campus · Lahore');
  });

  it('AC2: draws the uploaded logo and signature when they exist', () => {
    const html = buildReportCardHtml(snapshot(), null, {
      ...noAssets,
      logoDataUri: 'data:image/png;base64,AAA',
      signatureDataUri: 'data:image/png;base64,BBB',
    }).html;
    expect(html).toContain('data:image/png;base64,AAA');
    expect(html).toContain('data:image/png;base64,BBB');
  });

  it('prints a report symbol instead of marks where FR-I11 left one', () => {
    const html = buildReportCardHtml(
      snapshot({
        subjects: [{ ...snapshot().subjects[0]!, report_symbol: 'EX', obtained: null, max_marks: null, pct: null }],
      }),
      null,
      noAssets,
    ).html;
    expect(html).toContain('>EX<');
  });

  it('names the component a candidate failed on rather than only that they failed', () => {
    const html = buildReportCardHtml(
      snapshot({
        subjects: [
          {
            ...snapshot().subjects[0]!,
            is_pass: false,
            failed_components: [{ component: 'practical', obtained: 4, pass_marks: 10, max_marks: 25 }],
          },
        ],
      }),
      null,
      noAssets,
    ).html;
    expect(html).toContain('Failed: practical');
  });

  it('collects every Arabic-script string for the glyph coverage check', () => {
    expect(collectReportCardStrings(snapshot())).toContain('عائشہ نور');
    expect(collectReportCardStrings(snapshot())).toContain('انگریزی');
  });
});

/**
 * FR-J12 AC3. "each card begins on a new sheet so duplex printing does not mix
 * students" — a sheet, not a page. A one-page card followed only by a page
 * break puts the next child on side 2 of the same sheet, so the collation pads
 * an odd-page card with a blank side, off the page count read from its own
 * rendered bytes rather than off an assumption about the layout.
 */
describe('merged report cards', () => {
  const cards = [
    { snapshot: snapshot({ student: { ...snapshot().student, gr_number: 'MAIN-000001' } }), pageCount: 1 },
    { snapshot: snapshot({ student: { ...snapshot().student, gr_number: 'MAIN-000002' } }), pageCount: 1 },
    { snapshot: snapshot({ student: { ...snapshot().student, gr_number: 'MAIN-000003' } }), pageCount: 1 },
  ];

  it('keeps the order it was given, which the batch froze at enumeration', () => {
    const html = buildMergedReportCardHtml(cards, null, noAssets, 'Class 5').html;
    const order = [...html.matchAll(/data-gr="([^"]+)"/g)].map((m) => m[1]);
    expect(order).toEqual(['MAIN-000001', 'MAIN-000002', 'MAIN-000003']);
  });

  it('AC3: pads an odd-page card so the next child starts on a new sheet', () => {
    const html = buildMergedReportCardHtml(cards, null, noAssets, 'Class 5').html;
    // Two fillers, not three: nothing follows the last card onto its back.
    expect([...html.matchAll(/class="sheet-filler"/g)]).toHaveLength(2);
  });

  it('does not pad a card that already ends on a whole sheet', () => {
    const html = buildMergedReportCardHtml(
      [{ ...cards[0]!, pageCount: 2 }, cards[1]!],
      null,
      noAssets,
      'Class 5',
    ).html;
    expect([...html.matchAll(/class="sheet-filler"/g)]).toHaveLength(0);
  });

  it('is one document with one embedded stylesheet, not three concatenated files', () => {
    const html = buildMergedReportCardHtml(cards, null, noAssets, 'Class 5').html;
    expect([...html.matchAll(/<!doctype html>/gi)]).toHaveLength(1);
    expect([...html.matchAll(/@page \{ size: A4 portrait/g)]).toHaveLength(1);
  });

  it('takes the stamp out of position:fixed so it does not repeat on every sheet of the run', () => {
    const html = buildMergedReportCardHtml(cards, null, noAssets, 'Class 5').html;
    expect(html).toContain('.card .stamp { position: absolute; }');
  });

  it('renders each card through the same builder as the single card', () => {
    const single = buildReportCardHtml(cards[0]!.snapshot, null, noAssets).html;
    const merged = buildMergedReportCardHtml([cards[0]!], null, noAssets, 'Class 5').html;
    const marksTable = single.slice(single.indexOf('<table class="marks">'), single.indexOf('</table>'));
    expect(merged).toContain(marksTable);
  });
});

describe('promotion decision (FR-J04 AC4)', () => {
  it('prints the final decision in words a parent understands', () => {
    expect(promotionLine({ decision: 'promoted', subjects: [] })).toBe('Promoted');
    expect(promotionLine({ decision: 'promoted_on_trial', subjects: [] })).toBe('Promoted on trial');
    expect(promotionLine({ decision: 'detained', subjects: [] })).toBe('Detained in the same class');
  });

  it('names the compartment subjects', () => {
    expect(promotionLine({ decision: 'compartment', subjects: ['Maths', 'Physics'] })).toBe(
      'Compartment in Maths, Physics',
    );
  });

  it('prints nothing for a pending candidate or an older snapshot', () => {
    expect(promotionLine({ decision: 'pending', subjects: [] })).toBeNull();
    expect(promotionLine(undefined)).toBeNull();
    expect(promotionLine(null)).toBeNull();
  });

  it('puts the line on the card only when a decision exists', () => {
    const withDecision = buildReportCardHtml(
      snapshot({ promotion: { decision: 'promoted_on_trial', subjects: [] } }),
      null,
      noAssets,
    ).html;
    expect(withDecision).toContain('data-promotion');
    expect(withDecision).toContain('Promoted on trial');
    expect(buildReportCardHtml(snapshot(), null, noAssets).html).not.toContain('data-promotion');
  });
});
