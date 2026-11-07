import { describe, expect, it } from 'vitest';
import { buildStatutoryReport } from './statutory';

describe('buildStatutoryReport', () => {
  it('makes one column per deduction or employer contribution and totals them', () => {
    const r = buildStatutoryReport([
      { staffName: 'Zara', employeeCode: 'E2', grossPaisa: 100, taxPaisa: 10, components: [
        { code: 'BASIC', name: 'Basic', type: 'earning', amountPaisa: 100 },
        { code: 'EOBI_EE', name: 'EOBI', type: 'deduction', amountPaisa: 5 },
      ] },
      { staffName: 'Ali', employeeCode: 'E1', grossPaisa: 200, taxPaisa: 0, components: [
        { code: 'EOBI_EE', name: 'EOBI', type: 'deduction', amountPaisa: 5 },
        { code: 'EOBI_ER', name: 'EOBI employer', type: 'employer_contribution', amountPaisa: 25 },
      ] },
    ]);
    expect(r.columns.map((c) => c.code)).toEqual(['EOBI_EE', 'EOBI_ER']);
    expect(r.rows.map((x) => x.staffName)).toEqual(['Ali', 'Zara']);
    expect(r.rows[1]!.amounts).toEqual({ EOBI_EE: 5, EOBI_ER: 0 });
    expect(r.totals).toEqual({ grossPaisa: 300, taxPaisa: 10, amounts: { EOBI_EE: 10, EOBI_ER: 25 } });
  });
});
