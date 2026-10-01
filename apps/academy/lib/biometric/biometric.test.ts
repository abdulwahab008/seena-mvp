import { describe, expect, it } from 'vitest';
import { deriveSigningSecret, signBody, verifySignature } from './signature';
import { MAX_PUNCHES_PER_CALL, parseBatch } from './payload';

describe('biometric batch signature (FR-D08)', () => {
  const secret = deriveSigningSecret('raw-device-key');
  const body = JSON.stringify({ punches: [{ code: '101', time: '2026-08-03T08:00:00+05:00' }] });

  it('derives the secret as the sha256 hex of the raw key', () => {
    expect(secret).toMatch(/^[0-9a-f]{64}$/);
    expect(deriveSigningSecret('raw-device-key')).toBe(secret);
  });

  it('accepts a correct signature, with or without the sha256= prefix', () => {
    const sig = signBody(secret, body);
    expect(verifySignature(secret, body, sig)).toBe(true);
    expect(verifySignature(secret, body, `sha256=${sig}`)).toBe(true);
  });

  it('rejects a tampered body, a wrong key, a missing or malformed header', () => {
    const sig = signBody(secret, body);
    expect(verifySignature(secret, body + ' ', sig)).toBe(false);
    expect(verifySignature(deriveSigningSecret('other-key'), body, sig)).toBe(false);
    expect(verifySignature(secret, body, null)).toBe(false);
    expect(verifySignature(secret, body, 'not-hex')).toBe(false);
    expect(verifySignature(null, body, sig)).toBe(false);
  });
});

describe('biometric batch parsing (FR-D08)', () => {
  it('accepts an object with punches or a bare array and normalises codes and directions', () => {
    const a = parseBatch(JSON.stringify({ punches: [{ code: 101, time: '2026-08-03T08:00:00', direction: 'IN' }, { code: ' 7 ', time: 'x' }] }));
    expect(a).toEqual({ ok: true, punches: [{ code: '101', time: '2026-08-03T08:00:00', direction: 'in' }, { code: '7', time: 'x', direction: 'unknown' }] });
    expect(parseBatch(JSON.stringify([{ code: '1', time: 't' }])).ok).toBe(true);
  });

  it('refuses more than 1000 punches with 413', () => {
    const many = Array.from({ length: MAX_PUNCHES_PER_CALL + 1 }, (_, i) => ({ code: String(i), time: '2026-08-03T08:00:00+05:00' }));
    expect(parseBatch(JSON.stringify(many))).toMatchObject({ ok: false, status: 413 });
    expect(parseBatch(JSON.stringify(many.slice(0, MAX_PUNCHES_PER_CALL))).ok).toBe(true);
  });

  it('refuses bodies that are not a batch, but keeps a malformed entry so the database can count it as rejected', () => {
    expect(parseBatch('nope')).toMatchObject({ ok: false, status: 400 });
    expect(parseBatch(JSON.stringify({ punches: 'x' }))).toMatchObject({ ok: false, status: 400 });
    expect(parseBatch(JSON.stringify([{ nonsense: true }]))).toEqual({ ok: true, punches: [{ code: '', time: '', direction: 'unknown' }] });
  });
});
