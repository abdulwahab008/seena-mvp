import { describe, expect, it } from 'vitest';
import { buildTranscriptHtml, sessionStatusText, type TranscriptSession, type TranscriptSnapshot } from './html';

/** FR-J13. The sentences the transcript prints, away from the renderer. */
const session = (over: Partial<TranscriptSession> = {}): TranscriptSession => ({
  session_id: 's',
  session_name: '2019-20',
  starts_on: '2019-04-01',
  ends_on: '2020-03-31',
  campus_name: 'Old Town Campus',
  class_name: 'Class 3',
  section_name: 'A',
  status: 'complete',
  note: null,
  left_on: null,
  terms_completed: ['First Term', 'Final Term'],
  promotion_decision: 'promoted',
  aggregate_pct: 71.5,
  subjects: [{ subject_name: 'Maths', weighted_pct: 71.5, grade_label: 'A', is_pass: true }],
  ...over,
});

const snapshot = (over: Partial<TranscriptSnapshot> = {}): TranscriptSnapshot => ({
  school: 'Seena Public School',
  student: { name_en: 'Zainab Hussain', name_ur: null, father_name_en: 'Hussain Ali', gr_number: 'M-1', dob: '2008-02-02', gender: 'female' },
  sessions: [session()],
  serial_no: 'TRN-2026-000001',
  issued_on: '2026-10-01',
  issued_by_name: 'Tahira Aziz',
  issued_by_role: 'principal',
  purpose: 'Transfer Certificate',
  ...over,
});

describe('buildTranscriptHtml', () => {
  it('AC4: prints the serial number, the issuing officer and the issue date', () => {
    const html = buildTranscriptHtml(snapshot(), null).html;
    expect(html).toContain('data-serial>TRN-2026-000001');
    expect(html).toContain('data-issued-on>1 Oct 2026');
    expect(html).toContain('Tahira Aziz');
    expect(html).toContain('Principal');
  });

  it('AC1: every session appears in the order given, each with its campus', () => {
    const html = buildTranscriptHtml(
      snapshot({
        sessions: [
          session({ session_name: '2019-20', campus_name: 'Old Town Campus (closed)' }),
          session({ session_name: '2020-21', campus_name: 'Main Campus' }),
        ],
      }),
      null,
    ).html;
    expect(html.indexOf('2019-20')).toBeLessThan(html.indexOf('2020-21'));
    expect(html).toContain('data-campus>Old Town Campus (closed)');
    expect(html).toContain('data-campus>Main Campus');
    expect(html).toContain('2 sessions on record');
  });

  it('AC2: an incomplete session carries the database annotation and its completed terms', () => {
    const html = buildTranscriptHtml(
      snapshot({
        sessions: [session({ status: 'incomplete', note: 'incomplete — left March 2023', subjects: [], promotion_decision: null })],
      }),
      null,
    ).html;
    expect(html).toContain('incomplete — left March 2023');
    expect(html).toContain('Terms completed: First Term, Final Term');
  });

  it('AC3: a withheld session says withheld and discloses no marks', () => {
    const html = buildTranscriptHtml(snapshot({ sessions: [session({ status: 'withheld', note: 'withheld' })] }), null).html;
    expect(html).toContain('data-status="withheld"');
    expect(html).toContain('Result withheld.');
    expect(html).not.toContain('71.50');
    expect(html).not.toContain('Terms completed');
  });

  it('escapes names so a student cannot inject markup', () => {
    const html = buildTranscriptHtml(
      snapshot({ student: { ...snapshot().student, name_en: '<script>alert(1)</script>' } }),
      null,
    ).html;
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain('&lt;script&gt;');
  });

  it('is A4 portrait', () => {
    const doc = buildTranscriptHtml(snapshot(), null);
    expect(doc.pageFormat).toBe('A4');
    expect(doc.landscape).toBe(false);
  });
});

describe('sessionStatusText', () => {
  it('reads the decision on a complete year, and the plain words otherwise', () => {
    expect(sessionStatusText(session())).toBe('Promoted');
    expect(sessionStatusText(session({ promotion_decision: null }))).toBe('Complete');
    expect(sessionStatusText(session({ status: 'in_progress' }))).toBe('In progress');
    expect(sessionStatusText(session({ status: 'withheld' }))).toBe('Withheld');
  });
});
