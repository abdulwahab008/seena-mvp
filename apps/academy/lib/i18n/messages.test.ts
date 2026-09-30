import { describe, expect, it } from 'vitest';
import { coverage, dirFor, en, isLang, t, ur, type MessageKey } from './messages';

const EASTERN_ARABIC_DIGITS = /[٠-٩۰-۹]/;
const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

describe('t', () => {
  it('returns the Urdu string in Urdu and English in English', () => {
    expect(t('ur', 'nav.fees')).toBe('فیس');
    expect(t('en', 'nav.fees')).toBe('Fees');
  });

  it('falls back to English, never a raw key, when there is no Urdu string', () => {
    const original = ur['fees.totalDue'];
    delete ur['fees.totalDue'];
    try {
      expect(t('ur', 'fees.totalDue')).toBe('Total due');
      expect(t('ur', 'fees.totalDue')).not.toContain('fees.');
    } finally {
      ur['fees.totalDue'] = original;
    }
  });

  it('interpolates placeholders and leaves unknown ones visible rather than dropping them', () => {
    expect(t('en', 'fees.payWith', { amount: 'PKR 8,500', gateway: 'JazzCash' })).toBe('Pay PKR 8,500 with JazzCash');
    expect(t('en', 'fees.payWith', { amount: 'PKR 1' })).toContain('{gateway}');
  });
});

describe('locale files', () => {
  it('every Urdu key exists in English (no orphans)', () => {
    for (const key of Object.keys(ur)) expect(key in en).toBe(true);
  });

  it('Urdu strings keep exactly the placeholders of the English string', () => {
    for (const key of Object.keys(ur) as MessageKey[]) expect(placeholders(ur[key]!)).toEqual(placeholders(en[key]));
  });

  it('never use Eastern Arabic numerals — challan numbers and amounts must stay Latin', () => {
    for (const value of Object.values(ur)) expect(EASTERN_ARABIC_DIGITS.test(value)).toBe(false);
  });

  it('translates every portal string that ships today', () => {
    const c = coverage();
    expect(c.translated).toBe(c.total);
  });
});

describe('dirFor / isLang', () => {
  it('flips to right-to-left only for Urdu', () => {
    expect(dirFor('ur')).toBe('rtl');
    expect(dirFor('en')).toBe('ltr');
  });
  it('accepts only supported languages', () => {
    expect(isLang('ur')).toBe(true);
    expect(isLang('fr')).toBe(false);
    expect(isLang(undefined)).toBe(false);
  });
});

describe('PKR formatting is language independent', () => {
  it('uses Latin digits under the en-PK locale used everywhere', () => {
    expect((850000 / 100).toLocaleString('en-PK')).toBe('8,500');
  });
});
