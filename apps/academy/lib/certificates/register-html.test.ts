import { describe, expect, it } from 'vitest';
import {
  buildRegisterHtml,
  continuityStatement,
  registerDate,
  type RegisterContinuity,
  type RegisterRow,
} from './register-html';

function row(over: Partial<RegisterRow> = {}): RegisterRow {
  return {
    serial_seq: 146,
    serial_no: 'TC-2026-000146',
    status: 'issued',
    issued_at: '2026-06-30T09:15:00.000Z',
    gr_number: '2019-0442',
    student_name: 'Ali Raza',
    class_name: 'Class 1',
    cancelled_at: null,
    cancelled_reason: null,
    cancelled_by_name: null,
    replaced_by_serial_no: null,
    replaces_serial_no: null,
    ...over,
  };
}

const META = {
  schoolName: 'Seena Model High School',
  campusLabel: 'Main Campus (MAIN)',
  certificateTypeLabel: 'Transfer Certificate',
  academicYearLabel: '2026',
  printedAt: '13-08-2026',
  printedBy: 'Nusrat Jamil',
};

const CONTINUOUS: RegisterContinuity = {
  expected_count: 212,
  present_count: 212,
  unnumbered_count: 0,
  counter_value: 212,
  missing_seq: [],
  first_serial: 'TC-2026-000001',
  last_serial: 'TC-2026-000212',
};

describe('registerDate', () => {
  it('prints DD-MM-YYYY, the one date format an issued document uses', () => {
    expect(registerDate('2026-06-30T09:15:00.000Z')).toBe('30-06-2026');
  });

  it('leaves a missing or unparseable date blank rather than printing Invalid Date', () => {
    expect(registerDate(null)).toBe('');
    expect(registerDate('not a date')).toBe('');
  });
});

describe('continuityStatement', () => {
  it('AC3: states a complete run as continuous, with the numbers it covers', () => {
    expect(continuityStatement(CONTINUOUS)).toBe(
      'Serials TC-2026-000001 to TC-2026-000212 (212 allocated, 212 on the page) — a continuous run with no missing numbers.',
    );
  });

  it('AC3: names the missing numbers rather than hiding the hole', () => {
    const statement = continuityStatement({ ...CONTINUOUS, present_count: 210, missing_seq: [4, 88] });
    expect(statement).toContain('2 MISSING NUMBER(S): 4, 88.');
  });

  it('reports entries that carry no allocated serial separately from a gap', () => {
    expect(continuityStatement({ ...CONTINUOUS, unnumbered_count: 1 })).toContain(
      '1 entry(ies) carry no allocated serial.',
    );
  });

  it('says so plainly when nothing has been allocated yet', () => {
    expect(continuityStatement(null)).toBe('No serials have been allocated in this series.');
  });
});

describe('buildRegisterHtml', () => {
  it('prints landscape A4 — the register is wide and a wrapped column gets misread', () => {
    const doc = buildRegisterHtml([row()], CONTINUOUS, META);
    expect(doc.pageFormat).toBe('A4');
    expect(doc.landscape).toBe(true);
    expect(doc.html).toContain('@page { size: A4 landscape;');
  });

  it('AC2: a cancelled entry stays on the page, struck through, with its reason and who cancelled it', () => {
    const doc = buildRegisterHtml(
      [
        row(),
        row({
          serial_seq: 147,
          serial_no: 'TC-2026-000147',
          status: 'cancelled',
          cancelled_at: '2026-07-02T06:00:00.000Z',
          cancelled_reason: 'wrong date of birth',
          cancelled_by_name: 'Nusrat Jamil',
          replaced_by_serial_no: 'TC-2026-000212',
        }),
        row({ serial_seq: 148, serial_no: 'TC-2026-000148' }),
      ],
      CONTINUOUS,
      META,
    );
    expect(doc.html).toContain('<tr class="cancelled">');
    expect(doc.html).toContain('wrong date of birth · by Nusrat Jamil · 02-07-2026');
    expect(doc.html).toContain('Replaced by TC-2026-000212');
    expect(doc.html).toContain('tr.cancelled td.serial, tr.void td.serial { text-decoration: line-through; }');
  });

  it('AC2: and the run still reads 146, 147, 148 in order with nothing renumbered', () => {
    const doc = buildRegisterHtml(
      [
        row(),
        row({ serial_seq: 147, serial_no: 'TC-2026-000147', status: 'cancelled', cancelled_reason: 'wrong dob' }),
        row({ serial_seq: 148, serial_no: 'TC-2026-000148' }),
      ],
      CONTINUOUS,
      META,
    );
    const order = [...doc.html.matchAll(/<td class="seq">(\d+|—)<\/td>/g)].map((m) => m[1]);
    expect(order).toEqual(['146', '147', '148']);
  });

  it('AC2: the replacement names what it replaced, so the cross-reference reads both ways', () => {
    const doc = buildRegisterHtml(
      [row({ serial_seq: 212, serial_no: 'TC-2026-000212', replaces_serial_no: 'TC-2026-000147' })],
      CONTINUOUS,
      META,
    );
    expect(doc.html).toContain('Replaces TC-2026-000147');
  });

  it('marks a void entry as a document that never existed, keeping its number', () => {
    const doc = buildRegisterHtml([row({ status: 'void' })], CONTINUOUS, META);
    expect(doc.html).toContain('<tr class="void">');
    expect(doc.html).toContain('Document never issued');
    expect(doc.html).toContain('TC-2026-000146');
  });

  it('shows an entry that carries no allocated position rather than dropping it', () => {
    const doc = buildRegisterHtml([row({ serial_seq: null, serial_no: 'CC-HAND-WRITTEN' })], CONTINUOUS, META);
    expect(doc.html).toContain('<td class="seq">—</td>');
    expect(doc.html).toContain('CC-HAND-WRITTEN');
  });

  it('repeats the header row on every printed page — a ledger with headings on page one only is unreadable', () => {
    expect(buildRegisterHtml([row()], CONTINUOUS, META).html).toContain('thead { display: table-header-group; }');
  });

  it('escapes register content rather than letting a student name close a tag', () => {
    const doc = buildRegisterHtml([row({ student_name: 'Ali <script>alert(1)</script> Raza' })], CONTINUOUS, META);
    expect(doc.html).not.toContain('<script>');
    expect(doc.html).toContain('&lt;script&gt;');
  });

  it('states who printed the register and when, because that is what is handed over', () => {
    const doc = buildRegisterHtml([row()], CONTINUOUS, META);
    expect(doc.html).toContain('1 entry printed');
    expect(doc.html).toContain('Printed 13-08-2026 by Nusrat Jamil');
  });
});
