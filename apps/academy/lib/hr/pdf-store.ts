import { sha256Hex, verifyPdfDigest } from '@/lib/certificates/seal';

/**
 * FR-D17 AC4 / FR-D18: a Staff & HR PDF (an approved settlement, an issued certificate) is rendered ONCE. The first download renders it, stores
 * the bytes and seals their SHA-256 on the statement row (write-once in the database); every later
 * download streams the stored bytes and re-checks them against that hash. Nothing is recomputed, so
 * the file the employee signed is the file anyone gets later - and a stored object that no longer
 * matches its hash is refused rather than served.
 *
 * The I/O is injected so the decision logic is a plain function with a unit test.
 */
/** The row's sealed file, if it has one. */
export type SealedRow = { pdfStoragePath: string | null; pdfSha256: string | null };

export type PdfStoreIO = {
  download: (path: string) => Promise<Uint8Array | null>;
  /** Must fail (return false) rather than overwrite an existing object. */
  upload: (path: string, bytes: Uint8Array) => Promise<boolean>;
  /** Seals path + hash on the row; false when it was already sealed. */
  seal: (path: string, sha256: string) => Promise<boolean>;
  /** Re-reads the row (after losing a race to another first download). */
  reload: () => Promise<SealedRow>;
  render: () => Promise<Uint8Array>;
};

export type PdfResult =
  | { status: 'served' | 'rendered'; bytes: Uint8Array; sha256: string }
  | { status: 'missing' }
  | { status: 'tampered'; expected: string; observed: string };

async function serveSealed(row: SealedRow, io: PdfStoreIO): Promise<PdfResult> {
  if (!row.pdfStoragePath || !row.pdfSha256) return { status: 'missing' };
  const bytes = await io.download(row.pdfStoragePath);
  if (!bytes) return { status: 'missing' };
  const verdict = verifyPdfDigest(bytes, row.pdfSha256);
  if (verdict.status === 'mismatch') return { status: 'tampered', expected: verdict.expected ?? row.pdfSha256, observed: verdict.observed };
  return { status: 'served', bytes, sha256: verdict.observed };
}

export async function getOrRenderSealedPdf(row: SealedRow, storagePath: string, io: PdfStoreIO): Promise<PdfResult> {
  if (row.pdfSha256 && row.pdfStoragePath) return serveSealed(row, io);

  const bytes = await io.render();
  const sha256 = sha256Hex(bytes);
  const uploaded = await io.upload(storagePath, bytes);
  const sealed = uploaded && (await io.seal(storagePath, sha256));
  if (sealed) return { status: 'rendered', bytes, sha256 };

  // Another request rendered and sealed first: serve what won, not what this request rendered.
  const latest = await io.reload();
  if (latest.pdfSha256 && latest.pdfStoragePath) return serveSealed(latest, io);
  return { status: 'missing' };
}
