import { describe, expect, it } from 'vitest';
import { clientIpFromHeaders, parseForwardedIp } from './request-ip';

describe('parseForwardedIp', () => {
  it('takes the first hop of an x-forwarded-for chain', () => {
    expect(parseForwardedIp('203.0.113.9, 70.41.3.18, 150.172.238.178')).toBe('203.0.113.9');
  });

  it('accepts a single address', () => {
    expect(parseForwardedIp('198.51.100.20')).toBe('198.51.100.20');
  });

  it('strips a port from an IPv4 hop', () => {
    expect(parseForwardedIp('203.0.113.9:54321')).toBe('203.0.113.9');
  });

  it('unwraps a bracketed IPv6 literal', () => {
    expect(parseForwardedIp('[2001:db8::1]:443')).toBe('2001:db8::1');
  });

  it('accepts a bare IPv6 address', () => {
    expect(parseForwardedIp('2001:db8::1')).toBe('2001:db8::1');
  });

  // The header is client-supplied unless a trusted proxy overwrites it, so
  // junk in it is expected. It must yield null rather than reaching Postgres
  // and failing the approval it is attached to.
  it('drops anything that is not an address', () => {
    expect(parseForwardedIp('not-an-ip-address')).toBeNull();
    expect(parseForwardedIp('999.1.1.1')).toBeNull();
    expect(parseForwardedIp('<script>alert(1)</script>')).toBeNull();
    expect(parseForwardedIp('  ')).toBeNull();
  });

  it('is null for a missing header', () => {
    expect(parseForwardedIp(null)).toBeNull();
    expect(parseForwardedIp(undefined)).toBeNull();
    expect(parseForwardedIp('')).toBeNull();
  });
});

describe('clientIpFromHeaders', () => {
  it('prefers x-forwarded-for', () => {
    const headers = new Headers({ 'x-forwarded-for': '203.0.113.9', 'x-real-ip': '198.51.100.20' });
    expect(clientIpFromHeaders(headers)).toBe('203.0.113.9');
  });

  it('falls back to x-real-ip', () => {
    expect(clientIpFromHeaders(new Headers({ 'x-real-ip': '198.51.100.20' }))).toBe('198.51.100.20');
  });

  it('falls back to x-real-ip when x-forwarded-for is junk', () => {
    const headers = new Headers({ 'x-forwarded-for': 'unknown', 'x-real-ip': '198.51.100.20' });
    expect(clientIpFromHeaders(headers)).toBe('198.51.100.20');
  });

  // A request that reached the origin directly carries neither header. NULL
  // is the honest record of that; the pooler's own address would not be.
  it('is null when the request carried no forwarded address at all', () => {
    expect(clientIpFromHeaders(new Headers())).toBeNull();
  });
});
