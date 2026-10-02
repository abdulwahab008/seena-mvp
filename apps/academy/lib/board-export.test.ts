import { describe, expect, it } from 'vitest';
import { boardExportFieldLabel, boardExportFileName, buildBoardExportCsv } from './board-export';

const HEADERS = ['Sr. No.', 'Candidate Name', 'B-Form No.'];

describe('buildBoardExportCsv', () => {
  it('writes the headers in the order given and one line per candidate', () => {
    const csv = buildBoardExportCsv(
      HEADERS,
      [
        { student_id: 'a', cells: ['1', 'Ayesha Noor', '3520212345678'] },
        { student_id: 'b', cells: ['2', 'Bilal Ahmed', '3520212345679'] },
      ],
      { byteOrderMark: false },
    );
    expect(csv).toBe(
      'Sr. No.,Candidate Name,B-Form No.\r\n1,Ayesha Noor,3520212345678\r\n2,Bilal Ahmed,3520212345679\r\n',
    );
  });

  it('prefixes a UTF-8 BOM when the profile asks for one, so Excel does not mangle Urdu', () => {
    const withBom = buildBoardExportCsv(['Name'], [{ student_id: 'a', cells: ['عائشہ نور'] }], { byteOrderMark: true });
    expect(withBom.charCodeAt(0)).toBe(0xfeff);
    expect(Buffer.from(withBom, 'utf8').subarray(0, 3)).toEqual(Buffer.from([0xef, 0xbb, 0xbf]));
    expect(withBom).toContain('عائشہ نور');

    const withoutBom = buildBoardExportCsv(['Name'], [{ student_id: 'a', cells: ['عائشہ نور'] }], {
      byteOrderMark: false,
    });
    expect(withoutBom.charCodeAt(0)).not.toBe(0xfeff);
  });

  it('quotes commas, quotes and newlines rather than breaking the row apart', () => {
    const csv = buildBoardExportCsv(
      ['Address', 'Note'],
      [{ student_id: 'a', cells: ['House 4, Street 9', 'said "yes"\nlater'] }],
      { byteOrderMark: false },
    );
    expect(csv).toBe('Address,Note\r\n"House 4, Street 9","said ""yes""\nlater"\r\n');
  });

  it('writes an empty cell for a null, never the string null', () => {
    const csv = buildBoardExportCsv(HEADERS, [{ student_id: 'a', cells: ['1', 'Ayesha Noor', null] }], {
      byteOrderMark: false,
    });
    expect(csv).toBe('Sr. No.,Candidate Name,B-Form No.\r\n1,Ayesha Noor,\r\n');
  });

  it('produces a header-only file for an empty cohort rather than nothing at all', () => {
    expect(buildBoardExportCsv(HEADERS, [], { byteOrderMark: false })).toBe(
      'Sr. No.,Candidate Name,B-Form No.\r\n',
    );
  });
});

describe('boardExportFileName', () => {
  it('names the file after the board and class so a controller can tell two apart in a downloads folder', () => {
    expect(boardExportFileName('PUNJAB', '9', 'abcdef12-3456-7890-abcd-ef1234567890')).toBe('PUNJAB-9-abcdef12.csv');
  });

  it('flattens the underscore in AKU_EB rather than leaving it in a file name', () => {
    expect(boardExportFileName('AKU_EB', '11', 'abcdef12-3456-7890-abcd-ef1234567890')).toBe('AKU-EB-11-abcdef12.csv');
  });
});

describe('boardExportFieldLabel', () => {
  it('turns a field path into something a controller can act on', () => {
    expect(boardExportFieldLabel('student.b_form_no')).toBe('B-Form number');
    expect(boardExportFieldLabel('guardian.father_cnic')).toBe("Father's CNIC");
  });

  it('falls back to the raw path for a field a board profile invented', () => {
    expect(boardExportFieldLabel('student.made_up')).toBe('student.made_up');
  });
});
