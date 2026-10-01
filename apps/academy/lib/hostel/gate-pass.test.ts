import { describe, expect, it } from 'vitest';
import { gatePassPath, gatePassUrl, karachiLocalToIso, qrSvg } from './gate-pass';

describe('gate pass QR (FR-Q03 AC4)', () => {
  it('encodes a URL that resolves to the pass record', () => {
    const id = '0b8f1d3e-7a4c-4a52-9a8e-1d6c2f3b4a5e';
    expect(gatePassPath(id)).toBe(`/hostel/gate-passes/${id}`);
    expect(gatePassUrl('https://school.example/', id)).toBe(`https://school.example/hostel/gate-passes/${id}`);
  });
  it('draws an SVG whose pattern depends on the pass', async () => {
    const a = await qrSvg('https://school.example/hostel/gate-passes/a');
    const b = await qrSvg('https://school.example/hostel/gate-passes/b');
    expect(a.startsWith('<?xml') || a.startsWith('<svg')).toBe(true);
    expect(a).toContain('<svg');
    expect(a).not.toBe(b);
  });
  it('reads a datetime-local value as Pakistan time', () => {
    expect(karachiLocalToIso('2026-08-16T20:00')).toBe('2026-08-16T20:00:00+05:00');
    expect(new Date(karachiLocalToIso('2026-08-16T20:00')).toISOString()).toBe('2026-08-16T15:00:00.000Z');
  });
});
