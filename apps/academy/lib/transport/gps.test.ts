import { describe, expect, it } from 'vitest';
import { GpsPayloadError, adapterFor, genericAdapter, toIsoInstant, traccarAdapter } from './gps-adapter';
import { signBody, verifyHmacSignature } from './gps-auth';

describe('toIsoInstant', () => {
  it('reads ISO strings, epoch seconds and epoch milliseconds', () => {
    expect(toIsoInstant('2026-09-14T01:50:00Z')).toBe('2026-09-14T01:50:00.000Z');
    expect(toIsoInstant(1789350600)).toBe('2026-09-14T01:50:00.000Z');
    expect(toIsoInstant(1789350600000)).toBe('2026-09-14T01:50:00.000Z');
    expect(toIsoInstant('1789350600')).toBe('2026-09-14T01:50:00.000Z');
  });
  it('rejects garbage', () => {
    expect(() => toIsoInstant('yesterday-ish')).toThrow(GpsPayloadError);
    expect(() => toIsoInstant(undefined)).toThrow(GpsPayloadError);
  });
});

describe('genericAdapter', () => {
  it('keeps out-of-order pings in the order received (the database orders by fix time)', () => {
    const pings = genericAdapter.parse({
      pings: [
        { reg_no: 'LEB-1234', lat: 31.5, lng: 74.3, speed: 40, ts: '2026-09-14T01:50:10Z' },
        { reg_no: 'LEB-1234', lat: 31.49, lng: 74.29, speed_kmh: 38, heading: 90, ts: '2026-09-14T01:50:00Z' },
      ],
    });
    expect(pings.map((p) => p.device_ts)).toEqual(['2026-09-14T01:50:10.000Z', '2026-09-14T01:50:00.000Z']);
    expect(pings[1]).toMatchObject({ speed_kmh: 38, heading: 90 });
  });
  it('refuses a ping with no vehicle or coordinates', () => {
    expect(() => genericAdapter.parse({ pings: [{ lat: 1, lng: 2, ts: 1 }] })).toThrow('reg_no or vehicle_id');
    expect(() => genericAdapter.parse({ pings: [{ reg_no: 'X', lng: 2, ts: 1789350600 }] })).toThrow('lat');
    expect(() => genericAdapter.parse('nope')).toThrow(GpsPayloadError);
  });
});

describe('traccarAdapter', () => {
  it('converts knots to km/h and reads the device name as the registration', () => {
    const [p] = traccarAdapter.parse({ device: { name: 'LEB-1234' }, position: { latitude: 31.5, longitude: 74.3, speed: 10, course: 180, deviceTime: '2026-09-14T01:50:00Z' } });
    expect(p).toMatchObject({ reg_no: 'LEB-1234', speed_kmh: 18.5, heading: 180 });
  });
  it('is found by name, and unknown vendors are not', () => {
    expect(adapterFor('traccar')).toBe(traccarAdapter);
    expect(adapterFor(undefined)).toBe(genericAdapter);
    expect(adapterFor('acme')).toBeNull();
  });
});

describe('verifyHmacSignature', () => {
  const secret = 'a-long-enough-shared-secret';
  const body = '{"pings":[]}';
  it('accepts the right signature, with or without the sha256= prefix', () => {
    const sig = signBody(secret, body);
    expect(verifyHmacSignature(secret, body, sig)).toBe(true);
    expect(verifyHmacSignature(secret, body, `sha256=${sig}`)).toBe(true);
  });
  it('fails closed on a wrong signature, a tampered body, a missing header or a missing secret', () => {
    const sig = signBody(secret, body);
    expect(verifyHmacSignature(secret, body + ' ', sig)).toBe(false);
    expect(verifyHmacSignature(secret, body, 'deadbeef')).toBe(false);
    expect(verifyHmacSignature(secret, body, null)).toBe(false);
    expect(verifyHmacSignature(undefined, body, sig)).toBe(false);
    expect(verifyHmacSignature('short', body, signBody('short', body))).toBe(false);
  });
});
