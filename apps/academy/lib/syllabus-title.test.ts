import { describe, expect, it } from 'vitest';
import { pickTitle } from './syllabus-title';

describe('pickTitle (FR-H13 AC4)', () => {
  it('shows the Urdu title to an Urdu reader when it is populated', () => {
    expect(pickTitle('ur', 'Waves', 'لہریں')).toBe('لہریں');
  });
  it('falls back to English when the Urdu title is missing or blank', () => {
    expect(pickTitle('ur', 'Waves', null)).toBe('Waves');
    expect(pickTitle('ur', 'Waves', undefined)).toBe('Waves');
    expect(pickTitle('ur', 'Waves', '   ')).toBe('Waves');
  });
  it('always shows English to an English reader', () => {
    expect(pickTitle('en', 'Waves', 'لہریں')).toBe('Waves');
  });
});
