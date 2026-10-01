import { createHash } from 'node:crypto';
import { zip, type ZipEntry } from '@/lib/xlsx/writer';

/**
 * FR-A19: the pure parts of a tenant data export — CSV serialisation with a UTF-8 BOM,
 * the manifest, and the ZIP container. Nothing here touches the database.
 *
 * Why the BOM: Excel on Windows is what school offices run, and it mis-renders Urdu in a
 * UTF-8 CSV that lacks the three-byte EF BB BF marker. It is the cheapest line in the whole
 * feature and the difference between an export that works and a support ticket.
 */

export const UTF8_BOM = '﻿';

/**
 * Lossless, because the point of the file is that the school owns its records: numbers,
 * booleans, dates and Urdu text come out exactly as stored. The only change is defusing a
 * text cell that a spreadsheet would run as a formula (leading = or @, or +/- followed by
 * something that is not part of a number): that gets a leading apostrophe.
 */
export function csvCell(value: unknown): string {
  if (value === null || value === undefined) return '';
  let s: string;
  if (typeof value === 'string') {
    s = value;
    if (/^[=@\t\r]/.test(s) || /^[+-](?![\d.])/.test(s)) s = `'${s}`;
  } else if (typeof value === 'object') {
    s = JSON.stringify(value);
  } else {
    s = String(value);
  }
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function csvLine(values: readonly unknown[]): string {
  return values.map(csvCell).join(',') + '\r\n';
}

/** Header first (so an empty table still has its columns), then the rows in column order. */
export function csvChunk(columns: readonly string[], rows: readonly Record<string, unknown>[], withHeader: boolean): string {
  return (withHeader ? csvLine(columns) : '') + rows.map((r) => csvLine(columns.map((c) => r[c]))).join('');
}

export type ManifestFile = { file: string; table: string; rows: number; bytes: number };
export type Manifest = {
  format: 'seena-tenant-export/1';
  encoding: 'utf-8-bom';
  request_id: string;
  tenant_id: string;
  requested_by: string;
  generated_at: string;
  files: ManifestFile[];
  total_rows: number;
};

export function buildManifest(input: { requestId: string; tenantId: string; requestedBy: string; generatedAt: Date; files: ManifestFile[] }): Manifest {
  return {
    format: 'seena-tenant-export/1',
    encoding: 'utf-8-bom',
    request_id: input.requestId,
    tenant_id: input.tenantId,
    requested_by: input.requestedBy,
    generated_at: input.generatedAt.toISOString(),
    files: input.files,
    total_rows: input.files.reduce((s, f) => s + f.rows, 0),
  };
}

export function rowCountsByFile(manifest: Manifest): Record<string, number> {
  return Object.fromEntries(manifest.files.map((f) => [f.file, f.rows]));
}

export type BuiltArchive = { bytes: Uint8Array; sha256: string; manifest: Manifest };

/** csvByFile holds each file's COMPLETE text, BOM included. */
export function buildArchive(manifest: Manifest, csvByFile: ReadonlyMap<string, string>): BuiltArchive {
  const enc = new TextEncoder();
  const entries: ZipEntry[] = [
    ...manifest.files.map((f) => ({ name: f.file, data: enc.encode(csvByFile.get(f.file) ?? '') })),
    { name: 'manifest.json', data: enc.encode(JSON.stringify(manifest, null, 2) + '\n') },
  ];
  const bytes = zip(entries);
  return { bytes, sha256: createHash('sha256').update(bytes).digest('hex'), manifest };
}

/** Reads a stored (method 0) ZIP back — used by tests and by anyone verifying an archive. */
export function readStoredZip(bytes: Uint8Array): Map<string, Uint8Array> {
  const out = new Map<string, Uint8Array>();
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = 0;
  while (at + 30 <= bytes.length && dv.getUint32(at, true) === 0x04034b50) {
    const size = dv.getUint32(at + 18, true);
    const nameLen = dv.getUint16(at + 26, true);
    const extraLen = dv.getUint16(at + 28, true);
    const name = new TextDecoder().decode(bytes.subarray(at + 30, at + 30 + nameLen));
    const start = at + 30 + nameLen + extraLen;
    out.set(name, bytes.subarray(start, start + size));
    at = start + size;
  }
  return out;
}
