import { describe, expect, it } from 'vitest';
import { buildVerifyUrl, hashIp, hashToken, isPlausibleToken, padToMinimum, renderVerifyPage } from './verify-core';

describe('buildVerifyUrl', () => {
  it('carries only the opaque token', () => {
    expect(buildVerifyUrl('https://school.example/', 'abcDEF123_-xyz789AB')).toBe('https://school.example/verify/abcDEF123_-xyz789AB');
  });

  it('escapes anything that is not URL-safe', () => {
    expect(buildVerifyUrl('https://s.example', 'a b/c')).toBe('https://s.example/verify/a%20b%2Fc');
  });
});

describe('isPlausibleToken', () => {
  it('accepts the database alphabet and rejects everything else', () => {
    expect(isPlausibleToken('AbCdEfGhIjKlMnOpQrStUv')).toBe(true);
    expect(isPlausibleToken('short')).toBe(false);
    expect(isPlausibleToken('has spaces in it, definitely')).toBe(false);
    expect(isPlausibleToken("'; drop table certificate_issue; --")).toBe(false);
    expect(isPlausibleToken('x'.repeat(65))).toBe(false);
  });
});

describe('hashing', () => {
  it('never stores the address or the token itself', () => {
    expect(hashIp('203.0.113.9')).toMatch(/^[0-9a-f]{64}$/);
    expect(hashIp('203.0.113.9')).not.toContain('203');
    expect(hashIp(null)).toBeNull();
    expect(hashToken('tok')).toMatch(/^[0-9a-f]{64}$/);
    expect(hashToken('tok')).not.toBe(hashToken('tok2'));
  });
});

describe('padToMinimum', () => {
  it('waits out the remainder of the floor and no more', async () => {
    const slept: number[] = [];
    await padToMinimum(1000, 120, () => 1030, async (ms) => void slept.push(ms));
    expect(slept).toEqual([90]);
  });

  it('does not wait when the floor has already passed', async () => {
    const slept: number[] = [];
    await padToMinimum(1000, 120, () => 1500, async (ms) => void slept.push(ms));
    expect(slept).toEqual([]);
  });
});

describe('renderVerifyPage', () => {
  it('shows the valid headline in green and nothing else', () => {
    const html = renderVerifyPage({ http_status: 200, state: 'valid', headline: 'VALID - Transfer Certificate GHS-LHR/TC/2026/00147 issued 30-Jun-2026 to A* H (GR 2019-)' });
    expect(html).toContain('VALID - Transfer Certificate GHS-LHR/TC/2026/00147 issued 30-Jun-2026 to A* H (GR 2019-)');
    expect(html).toContain('data-state="valid"');
    expect(html).toContain('#14532d');
  });

  it('shows a cancelled certificate in red', () => {
    const html = renderVerifyPage({ http_status: 200, state: 'cancelled', headline: 'CANCELLED on 12-Jul-2026' });
    expect(html).toContain('CANCELLED on 12-Jul-2026');
    expect(html).toContain('#991b1b');
    expect(html).toContain('background:#fee2e2');
  });

  it('is generic when nothing is found', () => {
    const html = renderVerifyPage({ http_status: 404, state: 'not_found', headline: 'No certificate found for this code' });
    expect(html).toContain('No certificate found for this code');
  });

  it('escapes whatever it is handed', () => {
    const html = renderVerifyPage({ http_status: 200, state: 'valid', headline: '<script>alert(1)</script>' });
    expect(html).not.toContain('<script>alert');
    expect(html).toContain('&lt;script&gt;');
  });
});
