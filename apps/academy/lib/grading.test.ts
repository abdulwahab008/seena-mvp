import { describe, expect, it } from 'vitest';
import {
  bandForPct,
  FBISE_PRESET_BANDS,
  gradingBandCoverageError,
  roundPct,
  saveGradingSchemeSchema,
} from '@/lib/validation';

/**
 * FR-J01. The editor holds the same coverage rule
 * app.fn_grading_band_coverage_error() does, so these assertions are the
 * client half of the pgTAP ones in
 * supabase/tests/database/board_grading_scheme.test.sql — same inputs, same
 * sentences. If the two ever drift, one of these two suites goes red.
 */
const bands = FBISE_PRESET_BANDS.map((b) => ({
  gradeLabel: b.gradeLabel,
  minPct: b.minPct,
  maxPct: b.maxPct,
}));

describe('gradingBandCoverageError', () => {
  it('accepts the published FBISE scale', () => {
    expect(gradingBandCoverageError(bands)).toBeNull();
  });

  it('names the range 70-79 beside 80-100 leaves uncovered', () => {
    expect(
      gradingBandCoverageError([
        { gradeLabel: 'A1', minPct: 80, maxPct: 100 },
        { gradeLabel: 'A', minPct: 70, maxPct: 79 },
        { gradeLabel: 'F', minPct: 0, maxPct: 69.99 },
      ]),
    ).toBe('grading bands leave 79.00-80.00 uncovered');
  });

  it('names both bands of an overlap', () => {
    expect(
      gradingBandCoverageError([
        { gradeLabel: 'A1', minPct: 80, maxPct: 100 },
        { gradeLabel: 'A', minPct: 70, maxPct: 80 },
        { gradeLabel: 'F', minPct: 0, maxPct: 69.99 },
      ]),
    ).toBe('grading bands A and A1 overlap between 80.00 and 80.00');
  });

  it('names a floor that never reaches zero', () => {
    expect(
      gradingBandCoverageError([
        { gradeLabel: 'A1', minPct: 80, maxPct: 100 },
        { gradeLabel: 'F', minPct: 33, maxPct: 79.99 },
      ]),
    ).toBe('grading bands leave 0.00-33.00 uncovered');
  });

  it('names a ceiling short of a hundred', () => {
    expect(
      gradingBandCoverageError([
        { gradeLabel: 'A1', minPct: 80, maxPct: 99 },
        { gradeLabel: 'F', minPct: 0, maxPct: 79.99 },
      ]),
    ).toBe('grading bands leave 99.00-100.00 uncovered');
  });

  it('refuses a third decimal place rather than rounding it into storage', () => {
    expect(
      gradingBandCoverageError([
        { gradeLabel: 'A1', minPct: 79.995, maxPct: 100 },
        { gradeLabel: 'F', minPct: 0, maxPct: 79.994 },
      ]),
    ).toBe('band A1 bounds must have at most two decimal places');
  });

  it('refuses an empty scale', () => {
    expect(gradingBandCoverageError([])).toBe('a grading scheme needs at least one band');
  });
});

describe('grade boundary determinism', () => {
  // The property FR-J02 rides on: the grade is read off the number the report
  // card prints, not off the raw division.
  it.each([
    [32.995, 'E'],
    [32.994, 'F'],
    [33, 'E'],
    [39.99, 'E'],
    [79.99, 'A'],
    [80, 'A1'],
    [100, 'A1'],
    [0, 'F'],
    [75.294117647, 'A'],
    [45.882352941, 'D'],
  ])('%s grades as %s', (pct, label) => {
    expect(bandForPct(bands, pct)?.gradeLabel).toBe(label);
  });

  it('has no grade for a subject with no denominator', () => {
    expect(bandForPct(bands, null)).toBeNull();
  });

  it('rounds half away from zero, matching Postgres round(numeric, 2)', () => {
    expect(roundPct(32.995)).toBe(33);
    expect(roundPct(32.994)).toBe(32.99);
    expect(roundPct(75.294117647)).toBe(75.29);
  });
});

describe('saveGradingSchemeSchema', () => {
  it('requires at least one band', () => {
    const parsed = saveGradingSchemeSchema.safeParse({
      board: 'FBISE',
      name: 'FBISE 2025',
      effectiveFrom: '2025-04-01',
      bands: [],
    });
    expect(parsed.success).toBe(false);
  });

  it('refuses a band whose lower bound is above its upper', () => {
    const parsed = saveGradingSchemeSchema.safeParse({
      board: 'FBISE',
      name: 'FBISE 2025',
      effectiveFrom: '2025-04-01',
      bands: [{ gradeLabel: 'A', minPct: 80, maxPct: 70, isPass: true }],
    });
    expect(parsed.success).toBe(false);
  });

  it('accepts the preset', () => {
    const parsed = saveGradingSchemeSchema.safeParse({
      board: 'FBISE',
      name: 'FBISE 2025',
      effectiveFrom: '2025-04-01',
      bands: FBISE_PRESET_BANDS,
    });
    expect(parsed.success).toBe(true);
  });
});
