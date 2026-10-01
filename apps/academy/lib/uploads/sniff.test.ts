import { describe, expect, it } from 'vitest';
import { sniffMime } from './sniff';

const bytes = (...b: number[]) => Uint8Array.from([...b, ...new Array(16).fill(0)]);

describe('sniffMime', () => {
  it('recognises PDF, JPEG, PNG and WebP by their own bytes', () => {
    expect(sniffMime(bytes(0x25, 0x50, 0x44, 0x46, 0x2d, 0x31))).toBe('application/pdf');
    expect(sniffMime(bytes(0xff, 0xd8, 0xff, 0xe0))).toBe('image/jpeg');
    expect(sniffMime(bytes(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))).toBe('image/png');
    expect(sniffMime(bytes(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50))).toBe('image/webp');
  });
  it('refuses a Windows executable renamed to .pdf', () => {
    expect(sniffMime(bytes(0x4d, 0x5a, 0x90, 0x00))).toBeNull();
  });
  it('refuses a RIFF file that is not WebP, and an empty file', () => {
    expect(sniffMime(bytes(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x41, 0x56, 0x49, 0x20))).toBeNull();
    expect(sniffMime(new Uint8Array())).toBeNull();
  });
});
