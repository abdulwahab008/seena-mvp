import { createHash } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
import { buildArchive, buildManifest, csvCell, csvChunk, readStoredZip, rowCountsByFile, UTF8_BOM } from './archive';
import { processTenantExports } from './process';

describe('csv', () => {
  it('writes values losslessly: negatives, booleans, dates and Urdu come out as stored', () => {
    expect(csvCell(-5000)).toBe('-5000');
    expect(csvCell('-12.50')).toBe('-12.50');
    expect(csvCell(true)).toBe('true');
    expect(csvCell('2026-03-01')).toBe('2026-03-01');
    expect(csvCell('عائشہ احمد')).toBe('عائشہ احمد');
    expect(csvCell(null)).toBe('');
  });
  it('quotes commas, quotes and newlines', () => {
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(csvCell('line1\nline2')).toBe('"line1\nline2"');
  });
  it('defuses a text cell a spreadsheet would run as a formula, but not numbers', () => {
    expect(csvCell('=SUM(A1)')).toBe("'=SUM(A1)");
    expect(csvCell('@cmd')).toBe("'@cmd");
    expect(csvCell('-cmd')).toBe("'-cmd");
    expect(csvCell('+cmd|calc')).toBe("'+cmd|calc");
    expect(csvCell('+923001234567')).toBe('+923001234567');
    expect(csvCell(-1)).toBe('-1');
  });
  it('serialises json columns as json text', () => {
    expect(csvCell({ a: 1 })).toBe('"{""a"":1}"');
  });
  it('emits the header even when the table has no rows', () => {
    expect(csvChunk(['id', 'name'], [], true)).toBe('id,name\r\n');
  });
  it("orders values by the declared columns, not the row's key order", () => {
    expect(csvChunk(['b', 'a'], [{ a: 1, b: 2 }], false)).toBe('2,1\r\n');
  });
});

describe('the archive', () => {
  const files = [
    { file: 'students.csv', table: 'students', rows: 2, bytes: 0 },
    { file: 'marks.csv', table: 'marks', rows: 0, bytes: 0 },
  ];
  const manifest = buildManifest({ requestId: 'r1', tenantId: 't1', requestedBy: 'u1', generatedAt: new Date('2026-10-01T10:00:00Z'), files });
  const csv = new Map([
    ['students.csv', UTF8_BOM + csvChunk(['gr_number', 'name_ur'], [{ gr_number: 'TX1', name_ur: 'عائشہ احمد' }, { gr_number: 'TX2', name_ur: 'بلال خان' }], true)],
    ['marks.csv', UTF8_BOM + csvChunk(['id'], [], true)],
  ]);
  const built = buildArchive(manifest, csv);
  const unzipped = readStoredZip(built.bytes);

  it('holds every file plus manifest.json', () => {
    expect([...unzipped.keys()].sort()).toEqual(['manifest.json', 'marks.csv', 'students.csv']);
  });
  it('starts every CSV with the UTF-8 byte-order mark so Excel renders Urdu', () => {
    for (const name of ['students.csv', 'marks.csv']) {
      expect([...unzipped.get(name)!.subarray(0, 3)]).toEqual([0xef, 0xbb, 0xbf]);
    }
    expect(new TextDecoder().decode(unzipped.get('students.csv')!.subarray(3))).toContain('عائشہ احمد');
  });
  it('lists the row count of every file in the manifest', () => {
    const m = JSON.parse(new TextDecoder().decode(unzipped.get('manifest.json')!));
    expect(m.files.map((f: { file: string; rows: number }) => [f.file, f.rows])).toEqual([['students.csv', 2], ['marks.csv', 0]]);
    expect(m.total_rows).toBe(2);
    expect(rowCountsByFile(manifest)).toEqual({ 'students.csv': 2, 'marks.csv': 0 });
  });
  it('checksums the exact bytes it produced', () => {
    expect(built.sha256).toBe(createHash('sha256').update(built.bytes).digest('hex'));
  });
});

describe('processTenantExports', () => {
  it('streams every table in pages, uploads one archive and reports its checksum and counts', async () => {
    const students = Array.from({ length: 5001 }, (_, i) => ({ id: `s${i}`, name_ur: 'نام' }));
    const uploaded: { path: string; bytes: Uint8Array }[] = [];
    const calls: { fn: string; args?: Record<string, unknown> }[] = [];
    const rpc = vi.fn(async (fn: string, args?: Record<string, unknown>) => {
      calls.push({ fn, args });
      if (fn === 'claim_tenant_export') return { data: [{ request_id: 'req-1', tenant_id: 'ten-1', requested_by: 'usr-1' }], error: null };
      if (fn === 'tenant_export_tables')
        return { data: [{ table_key: 'students', file_name: 'students.csv', columns: ['id', 'name_ur'] }, { table_key: 'marks', file_name: 'marks.csv', columns: ['id'] }], error: null };
      if (fn === 'tenant_export_page') {
        const { p_table_key, p_offset, p_limit } = args as { p_table_key: string; p_offset: number; p_limit: number };
        return { data: p_table_key === 'students' ? students.slice(p_offset, p_offset + p_limit) : [], error: null };
      }
      return { data: null, error: null };
    });
    const db = {
      rpc,
      storage: { from: () => ({ upload: async (path: string, bytes: Uint8Array) => (uploaded.push({ path, bytes }), { error: null }) }) },
    } as never;

    expect(await processTenantExports(db)).toEqual({ processed: 1, failed: 0 });
    const pages = calls.filter((c) => c.fn === 'tenant_export_page' && c.args?.p_table_key === 'students');
    expect(pages.map((p) => p.args!.p_offset)).toEqual([0, 5000]);
    expect(uploaded[0]!.path).toBe('ten-1/req-1.zip');
    const done = calls.find((c) => c.fn === 'complete_tenant_export')!.args!;
    expect(done.p_row_counts).toEqual({ 'students.csv': 5001, 'marks.csv': 0 });
    expect(done.p_checksum).toBe(createHash('sha256').update(uploaded[0]!.bytes).digest('hex'));
    expect(done.p_bytes).toBe(uploaded[0]!.bytes.length);
    const csv = new TextDecoder('utf-8', { ignoreBOM: true }).decode(readStoredZip(uploaded[0]!.bytes).get('students.csv')!);
    expect(csv.charCodeAt(0)).toBe(0xfeff);
    expect(csv.split('\r\n').length).toBe(5001 + 2);   // header + rows + trailing empty
  });

  it('marks the request failed (and keeps nothing) when a page cannot be read', async () => {
    const calls: string[] = [];
    const db = {
      rpc: async (fn: string) => {
        calls.push(fn);
        if (fn === 'claim_tenant_export') return { data: [{ request_id: 'r', tenant_id: 't', requested_by: 'u' }], error: null };
        if (fn === 'tenant_export_tables') return { data: [{ table_key: 'students', file_name: 'students.csv', columns: ['id'] }], error: null };
        if (fn === 'tenant_export_page') return { data: null, error: { message: 'boom' } };
        return { data: null, error: null };
      },
      storage: { from: () => ({ upload: async () => ({ error: null }) }) },
    } as never;
    expect(await processTenantExports(db)).toEqual({ processed: 0, failed: 1 });
    expect(calls).toContain('fail_tenant_export');
    expect(calls).not.toContain('complete_tenant_export');
  });
});
