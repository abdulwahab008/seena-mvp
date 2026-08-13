import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  MM_PER_INCH,
  PAGE_MARGIN_LEFT_MM,
  PAGE_MARGIN_TOP_MM,
  REQUIRED_DPI,
  anchorToPageArea,
  checkPrintResolution,
  checkSealResolution,
  effectiveDpi,
  minPixelsFor,
  sha256Hex,
  verifyPdfDigest,
  type CertificateSeal,
} from './seal';

// FR-T09. Three pieces of arithmetic decide whether a certificate can be
// forged undetectably, printed legibly, or refused wrongly, so each is
// tested here rather than only through the route handler that calls it.

function seal(over: Partial<CertificateSeal> = {}): CertificateSeal {
  return {
    signing_identity_id: 'id-1',
    holder_name: 'Farhat Jabeen',
    designation: 'Principal',
    valid_from: '2026-01-01',
    valid_to: null,
    signature_storage_path: 't/c/signature/1.png',
    signature_width_px: 900,
    signature_height_px: 300,
    stamp_storage_path: 't/c/stamp/1.png',
    stamp_width_px: 800,
    stamp_height_px: 800,
    signature_anchor_x_mm: 140,
    signature_anchor_y_mm: 235,
    signature_width_mm: 45,
    stamp_anchor_x_mm: 35,
    stamp_anchor_y_mm: 232,
    stamp_width_mm: 35,
    stamp_opacity: 0.6,
    ...over,
  };
}

describe('sha256Hex', () => {
  it('is the sha-256 of the bytes, as 64 lower-case hex characters', () => {
    const bytes = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d]); // '%PDF-'
    expect(sha256Hex(bytes)).toBe(createHash('sha256').update(bytes).digest('hex'));
    expect(sha256Hex(bytes)).toMatch(/^[0-9a-f]{64}$/);
  });

  it('is the digest the database column will accept', () => {
    // chk_cert_issue_pdf_sha256 is '^[0-9a-f]{64}$'; a digest this side that
    // the column refuses would fail at issue time, not here.
    expect(sha256Hex(new Uint8Array(0))).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  it('changes when a single byte of a large document changes', () => {
    const original = new Uint8Array(4096).fill(7);
    const tampered = new Uint8Array(original);
    tampered[2048] = 8;
    expect(sha256Hex(tampered)).not.toBe(sha256Hex(original));
  });
});

describe('the 300 DPI adequacy check', () => {
  it('AC1: 45mm at 300 DPI needs 532 pixels across', () => {
    expect(minPixelsFor(45, REQUIRED_DPI)).toBe(532);
    // ceil, not round: 531.49... pixels is not enough pixels.
    expect(minPixelsFor(45, REQUIRED_DPI)).toBe(Math.ceil((45 / MM_PER_INCH) * 300));
  });

  it('reports what an image actually prints at', () => {
    expect(Math.round(effectiveDpi(532, 45))).toBe(300);
    expect(Math.round(effectiveDpi(266, 45))).toBe(150);
    expect(effectiveDpi(900, 0)).toBe(0);
  });

  it('passes an image with exactly enough pixels and fails one a pixel short', () => {
    expect(checkPrintResolution(532, 45).ok).toBe(true);
    expect(checkPrintResolution(531, 45).ok).toBe(false);
    expect(checkPrintResolution(531, 45).requiredPx).toBe(532);
  });

  it('accepts a seal whose signature and stamp both clear their own box', () => {
    expect(checkSealResolution(seal())).toEqual({ ok: true, failures: [] });
  });

  it('rejects a signature that would have to be upscaled, and says by how much', () => {
    const report = checkSealResolution(seal({ signature_width_px: 200 }));
    expect(report.ok).toBe(false);
    expect(report.failures).toHaveLength(1);
    expect(report.failures[0]).toContain('signature 200px');
    expect(report.failures[0]).toContain('needs 532px');
  });

  it('checks the stamp against the stamp box, not the signature box', () => {
    // 500px is fine for a 35mm stamp (needs 414) but not for a 45mm one.
    expect(checkSealResolution(seal({ stamp_width_px: 500 })).ok).toBe(true);
    expect(checkSealResolution(seal({ stamp_width_px: 400 })).ok).toBe(false);
  });

  it('reports both failures rather than stopping at the first', () => {
    expect(checkSealResolution(seal({ signature_width_px: 100, stamp_width_px: 100 })).failures).toHaveLength(2);
  });

  it('ignores the stamp when there is none — a stamp is optional, a signature is not', () => {
    expect(checkSealResolution(seal({ stamp_storage_path: null, stamp_width_px: null })).ok).toBe(true);
  });

  it('scales the floor with a wider anchor box', () => {
    // The render checks the template's ACTUAL box, so a template that prints
    // the signature 90mm wide needs twice the pixels.
    expect(checkSealResolution(seal({ signature_width_mm: 90 })).ok).toBe(false);
    expect(minPixelsFor(90)).toBe(1063);
  });
});

describe('anchorToPageArea', () => {
  it('AC1: a (140mm, 235mm) page anchor lands inside the page area, margins subtracted', () => {
    expect(anchorToPageArea(140, 235)).toEqual({ leftMm: 140 - PAGE_MARGIN_LEFT_MM, topMm: 235 - PAGE_MARGIN_TOP_MM });
  });

  it('allows an anchor inside the page margin, which is where a stamp sometimes sits', () => {
    expect(anchorToPageArea(10, 8)).toEqual({ leftMm: -8, topMm: -8 });
  });
});

describe('the tamper comparison', () => {
  const bytes = new Uint8Array([1, 2, 3, 4, 5]);

  it('matches when the stored bytes still hash to what was sealed at issue', () => {
    const verdict = verifyPdfDigest(bytes, sha256Hex(bytes));
    expect(verdict.status).toBe('match');
    expect(verdict.observed).toBe(verdict.expected);
    expect(verdict.bytes).toBe(5);
  });

  it('AC2: a single altered byte is a mismatch, and both digests are reported', () => {
    const sealed = sha256Hex(bytes);
    const tampered = new Uint8Array([1, 2, 3, 4, 6]);
    const verdict = verifyPdfDigest(tampered, sealed);
    expect(verdict.status).toBe('mismatch');
    expect(verdict.expected).toBe(sealed);
    expect(verdict.observed).toBe(sha256Hex(tampered));
  });

  it('AC2: a truncated document is a mismatch too — length is inside the digest', () => {
    expect(verifyPdfDigest(bytes.subarray(0, 4), sha256Hex(bytes)).status).toBe('mismatch');
  });

  it('calls a row with no sealed digest unverifiable rather than tampered', () => {
    // A certificate issued before this FR existed. Refusing to serve it
    // would be inventing a forgery, not catching one.
    const verdict = verifyPdfDigest(bytes, null);
    expect(verdict.status).toBe('unverifiable');
    expect(verdict.expected).toBeNull();
    expect(verdict.observed).toBe(sha256Hex(bytes));
  });

  it('is case-sensitive, so an upper-case digest never silently matches', () => {
    expect(verifyPdfDigest(bytes, sha256Hex(bytes).toUpperCase()).status).toBe('mismatch');
  });
});
