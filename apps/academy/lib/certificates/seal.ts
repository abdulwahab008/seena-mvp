import { createHash } from 'node:crypto';

/**
 * FR-T09: the three pieces of arithmetic the signature/stamp feature turns
 * on, kept out of the render and the route handler so each is a pure
 * function with a unit test rather than a line buried in an I/O path.
 *
 *   * the digest that gets frozen onto the register row and re-checked on
 *     every download,
 *   * whether an uploaded image carries enough pixels to print at 300 DPI in
 *     the box the template anchors it to,
 *   * where a page-absolute mm anchor lands inside a `@page`-margined sheet.
 */

export const MM_PER_INCH = 25.4;

/** AC1's floor. A statutory document is printed, not viewed. */
export const REQUIRED_DPI = 300;

/**
 * The `@page` margins lib/certificates/html.ts sets. A `position: fixed`
 * element in paged media is positioned against the PAGE AREA — the sheet
 * minus its margins — so a page-absolute anchor has to have them subtracted.
 * Stated here, next to the arithmetic that uses them, and asserted in the
 * tests against the stylesheet that declares them.
 */
export const PAGE_MARGIN_TOP_MM = 16;
export const PAGE_MARGIN_LEFT_MM = 18;

/** The seal block FR-T09 freezes onto certificate_issue.payload_snapshot. */
export type CertificateSeal = {
  signing_identity_id: string;
  holder_name: string;
  designation: string;
  valid_from: string;
  valid_to: string | null;
  signature_storage_path: string;
  signature_width_px: number;
  signature_height_px: number;
  stamp_storage_path: string | null;
  stamp_width_px: number | null;
  stamp_height_px: number | null;
  signature_anchor_x_mm: number;
  signature_anchor_y_mm: number;
  signature_width_mm: number;
  stamp_anchor_x_mm: number;
  stamp_anchor_y_mm: number;
  stamp_width_mm: number;
  stamp_opacity: number;
};

export function sha256Hex(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

/** Pixels an image must carry across to print `mm` wide at `dpi`. */
export function minPixelsFor(mm: number, dpi: number = REQUIRED_DPI): number {
  return Math.ceil((mm / MM_PER_INCH) * dpi);
}

/** What an image of `px` pixels actually prints at when stretched to `mm`. */
export function effectiveDpi(px: number, mm: number): number {
  if (mm <= 0) return 0;
  return (px * MM_PER_INCH) / mm;
}

export type DpiCheck = { ok: boolean; dpi: number; requiredPx: number; widthPx: number; boxMm: number };

/**
 * AC1's "at 300 DPI", checked rather than asserted. Nothing downstream can
 * add detail to an image that does not have it, so an inadequate source is
 * refused instead of being silently upscaled onto a board document.
 */
export function checkPrintResolution(widthPx: number, boxMm: number, dpi: number = REQUIRED_DPI): DpiCheck {
  const requiredPx = minPixelsFor(boxMm, dpi);
  return { ok: widthPx >= requiredPx, dpi: effectiveDpi(widthPx, boxMm), requiredPx, widthPx, boxMm };
}

export type SealResolutionReport = { ok: boolean; failures: string[] };

/** Both images of a seal, each against the box its own anchor gives it. */
export function checkSealResolution(seal: CertificateSeal, dpi: number = REQUIRED_DPI): SealResolutionReport {
  const failures: string[] = [];

  const signature = checkPrintResolution(seal.signature_width_px, seal.signature_width_mm, dpi);
  if (!signature.ok) {
    failures.push(
      `signature ${signature.widthPx}px across a ${signature.boxMm}mm box is ${Math.round(signature.dpi)} DPI (needs ${signature.requiredPx}px for ${dpi} DPI)`,
    );
  }

  if (seal.stamp_storage_path && seal.stamp_width_px) {
    const stamp = checkPrintResolution(seal.stamp_width_px, seal.stamp_width_mm, dpi);
    if (!stamp.ok) {
      failures.push(
        `stamp ${stamp.widthPx}px across a ${stamp.boxMm}mm box is ${Math.round(stamp.dpi)} DPI (needs ${stamp.requiredPx}px for ${dpi} DPI)`,
      );
    }
  }

  return { ok: failures.length === 0, failures };
}

/**
 * A page-absolute anchor, in the coordinate space a `position: fixed` box
 * actually lives in. Negative values are legal and mean "in the margin",
 * which is where a stamp legitimately sometimes sits.
 */
export function anchorToPageArea(xMm: number, yMm: number): { leftMm: number; topMm: number } {
  return { leftMm: xMm - PAGE_MARGIN_LEFT_MM, topMm: yMm - PAGE_MARGIN_TOP_MM };
}

export type DigestVerdict = {
  status: 'match' | 'mismatch' | 'unverifiable';
  expected: string | null;
  observed: string;
  bytes: number;
};

/**
 * AC2's comparison. 'unverifiable' is a register row with no digest — one
 * issued before this FR existed, since every issue since is sealed before
 * its link is handed out. It is NOT a mismatch and must not 409: refusing to
 * serve a document because it predates the tamper check would be inventing a
 * forgery, not catching one.
 */
export function verifyPdfDigest(bytes: Uint8Array, expected: string | null): DigestVerdict {
  const observed = sha256Hex(bytes);
  if (!expected) return { status: 'unverifiable', expected: null, observed, bytes: bytes.byteLength };
  return {
    status: expected === observed ? 'match' : 'mismatch',
    expected,
    observed,
    bytes: bytes.byteLength,
  };
}
