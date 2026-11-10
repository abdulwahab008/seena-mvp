import { describe, expect, it } from 'vitest';
import { toGuardianImportRows } from './guardian-import';

describe('toGuardianImportRows', () => {
  it('maps columns in any order and numbers rows from the file line', () => {
    const r = toGuardianImportRows([
      ['father_phone', 'GR_Number', 'father_cnic'],
      ['0300 1234567', '1001', '35202-1234567-1'],
      ['', '', ''],
      ['', '1002', '3520212345672'],
    ]);
    expect(r).toEqual({
      ok: true,
      rows: [
        { row: 2, gr_number: '1001', father_name: '', father_cnic: '35202-1234567-1', father_phone: '0300 1234567' },
        { row: 4, gr_number: '1002', father_name: '', father_cnic: '3520212345672', father_phone: '' },
      ],
    });
  });

  it('refuses a file without gr_number, without any contact column, or with unknown columns', () => {
    expect(toGuardianImportRows([['father_cnic']]).ok).toBe(false);
    expect(toGuardianImportRows([['gr_number', 'father_name']]).ok).toBe(false);
    expect(toGuardianImportRows([['gr_number', 'father_cnic', 'mother_cnic']])).toMatchObject({ ok: false, message: expect.stringContaining('mother_cnic') });
  });
});
