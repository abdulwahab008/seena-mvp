import { describe, expect, it } from 'vitest';
import { parseSettlement } from './settlement-parser';

describe('parseSettlement', () => {
  it('reads the 8,500 payment settled at 8,415', () => {
    const r = parseSettlement('Transaction ID,Settlement Date,Gross Amount,Commission,Net Amount\nTX1,2026-08-12,"8,500.00",85.00,"8,415.00"');
    expect(r.fatal).toBeNull();
    expect(r.lines[0]).toMatchObject({ gateway_txn_id: 'TX1', settlement_date: '2026-08-12', gross_paisa: 850000, commission_paisa: 8500, net_paisa: 841500, error: null });
  });

  it('derives the missing one of commission and net', () => {
    const a = parseSettlement('txn_id,settled_on,amount,fee\nTX1,12/08/2026,8500,85').lines[0];
    expect(a).toMatchObject({ commission_paisa: 8500, net_paisa: 841500 });
    const b = parseSettlement('txn_id,settled_on,amount,net\nTX1,12-Aug-2026,8500,8415').lines[0];
    expect(b).toMatchObject({ commission_paisa: 8500, net_paisa: 841500, settlement_date: '2026-08-12' });
  });

  it('keeps a row whose amounts do not add up, with its raw text', () => {
    const l = parseSettlement('txn_id,date,gross,commission,net\nTX1,2026-08-12,8500,85,8000').lines[0]!;
    expect(l.error).toBe('AMOUNTS_DO_NOT_ADD_UP');
    expect(l.raw_line).toBe('TX1,2026-08-12,8500,85,8000');
    expect(l.gross_paisa).toBeNull();
  });

  it('flags every problem on a row, never throws', () => {
    expect(parseSettlement('txn_id,date,gross,commission\n,not-a-date,abc,5').lines[0]!.error).toBe('MISSING_TXN_ID,BAD_DATE,BAD_GROSS');
  });

  it('refuses a file without the columns it needs', () => {
    expect(parseSettlement('foo,bar\n1,2').fatal).toContain('transaction id');
    expect(parseSettlement('txn_id,date,gross\nTX1,2026-08-12,500').fatal).toContain('commission or net');
  });
});
