import { describe, expect, it, vi } from 'vitest';
import { buildStatementDocument, formatRupees, netPayablePaisa, parseRupeesToPaisa, signedRupees, type StatementData } from './statement';
import { getOrRenderSealedPdf, type PdfStoreIO, type SealedRow } from '@/lib/hr/pdf-store';
import { sha256Hex } from '@/lib/certificates/seal';

describe('settlement money formatting (FR-D17)', () => {
  it('prints integer paisa as rupees with two decimals', () => {
    expect(formatRupees(5161290)).toBe('51,612.90');
    expect(formatRupees(2666670)).toBe('26,666.70');
    expect(formatRupees(6666675)).toBe('66,666.75');
    expect(formatRupees(5)).toBe('0.05');
    expect(formatRupees(0)).toBe('0.00');
  });

  it('shows deductions with a minus sign', () => {
    expect(signedRupees({ amountPaisa: 6666675, sign: -1 })).toBe('-66,666.75');
    expect(signedRupees({ amountPaisa: 5161290, sign: 1 })).toBe('+51,612.90');
  });

  it('sums the already-rounded lines so the lines always tie to the total', () => {
    const lines = [
      { amountPaisa: 5161290, sign: 1 as const },
      { amountPaisa: 2666670, sign: 1 as const },
      { amountPaisa: 6666675, sign: -1 as const },
    ];
    expect(netPayablePaisa(lines)).toBe(1161285);
    expect(formatRupees(netPayablePaisa(lines))).toBe('11,612.85');
  });
});

describe('typed rupee amounts (FR-D17)', () => {
  it('parses plain amounts to paisa and rejects everything else', () => {
    expect(parseRupeesToPaisa('1,500.5')).toBe(150050);
    expect(parseRupeesToPaisa('20000')).toBe(2000000);
    expect(parseRupeesToPaisa(' 0.05 ')).toBe(5);
    for (const bad of ['', '0', '-5', '12.345', 'abc', '1e5', '1.2.3']) expect(parseRupeesToPaisa(bad)).toBeNull();
  });
});

describe('settlement statement document (FR-D17)', () => {
  const data: StatementData = {
    schoolName: 'Bright Future School',
    schoolNameUr: 'برائٹ فیوچر اسکول',
    staffName: 'Ayesha <Khan>',
    employeeCode: 'SA-MAIN-0007',
    exitType: 'resignation',
    noticeDate: '2026-08-15',
    lastWorkingDate: '2026-08-20',
    version: 1,
    approvedAt: '2026-08-21T09:00:00Z',
    approvedByName: 'Accounts',
    lines: [
      { lineType: 'salary', description: 'Salary 01 Aug 2026 to 20 Aug 2026 (20 of 31 days)', amountPaisa: 5161290, sign: 1 },
      { lineType: 'notice_recovery', description: 'Notice shortfall recovery: 25 day(s)', amountPaisa: 6666675, sign: -1 },
    ],
    netPayablePaisa: -1505385,
  };

  it('lists each line in the right column, escapes names and states the net', () => {
    const { html } = buildStatementDocument(data, null);
    expect(html).toContain('51,612.90');
    expect(html).toContain('66,666.75');
    expect(html).toContain('Ayesha &lt;Khan&gt;');
    expect(html).toContain('Net recoverable from the employee');
    expect(html).toContain('-15,053.85');
    expect(html).toContain('lang="ur"');
    expect(html).toContain('برائٹ فیوچر اسکول');
  });
});

describe('settlement PDF is rendered once (FR-D17 AC4)', () => {
  const pdf = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 1, 2, 3, 4]); // %PDF-...

  function makeIO() {
    const store = new Map<string, Uint8Array>();
    const row: SealedRow = { pdfStoragePath: null, pdfSha256: null };
    const render = vi.fn(async () => pdf);
    const io: PdfStoreIO = {
      render,
      download: async (p) => store.get(p) ?? null,
      upload: async (p, b) => {
        if (store.has(p)) return false;
        store.set(p, b);
        return true;
      },
      seal: async (p, s) => {
        if (row.pdfSha256) return false;
        row.pdfStoragePath = p;
        row.pdfSha256 = s;
        return true;
      },
      reload: async () => ({ ...row }),
    };
    return { io, row, store, render };
  }

  it('renders on the first download, then serves the stored bytes with the same hash and never renders again', async () => {
    const { io, row, render } = makeIO();
    const first = await getOrRenderSealedPdf({ ...row }, 't/s.pdf', io);
    expect(first.status).toBe('rendered');
    const second = await getOrRenderSealedPdf({ ...row }, 't/s.pdf', io);
    expect(second.status).toBe('served');
    if (first.status !== 'missing' && first.status !== 'tampered' && second.status === 'served') {
      expect(second.sha256).toBe(first.sha256);
      expect(second.sha256).toBe(sha256Hex(pdf));
      expect(Buffer.from(second.bytes).equals(Buffer.from(pdf))).toBe(true);
    }
    expect(render).toHaveBeenCalledTimes(1);
  });

  it('refuses a stored object whose bytes no longer match the sealed hash', async () => {
    const { io, row, store } = makeIO();
    await getOrRenderSealedPdf({ ...row }, 't/s.pdf', io);
    store.set('t/s.pdf', new Uint8Array([9, 9, 9]));
    const again = await getOrRenderSealedPdf({ ...row }, 't/s.pdf', io);
    expect(again.status).toBe('tampered');
  });

  it('reports a missing object instead of re-rendering over a sealed hash', async () => {
    const { io, row, store, render } = makeIO();
    await getOrRenderSealedPdf({ ...row }, 't/s.pdf', io);
    store.clear();
    const again = await getOrRenderSealedPdf({ ...row }, 't/s.pdf', io);
    expect(again.status).toBe('missing');
    expect(render).toHaveBeenCalledTimes(1);
  });

  it('when two first downloads race, the loser serves what the winner sealed', async () => {
    const { io, row } = makeIO();
    const stale: SealedRow = { pdfStoragePath: null, pdfSha256: null };
    const a = await getOrRenderSealedPdf({ ...stale }, 't/s.pdf', io);
    const b = await getOrRenderSealedPdf({ ...stale }, 't/s.pdf', io);
    expect(a.status).toBe('rendered');
    expect(b.status).toBe('served');
    expect(row.pdfSha256).toBe(sha256Hex(pdf));
  });
});
