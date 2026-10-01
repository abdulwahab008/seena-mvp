import { describe, expect, it } from 'vitest';
import { appraisalScore, isEligible, parseCompetencies, serviceDays } from './scoring';

describe('appraisal scoring (FR-D14)', () => {
  const weights = [25, 20, 20, 15, 10, 10];

  it('six competencies weighted 25/20/20/15/10/10 all rated 4 score 80.00', () => {
    expect(appraisalScore(weights, [4, 4, 4, 4, 4, 4])).toBe(80);
  });

  it('weights ratings individually', () => {
    expect(appraisalScore(weights, [5, 3, 4, 2, 1, 5])).toBe(71);
    expect(appraisalScore(weights, [5, 5, 5, 5, 5, 5])).toBe(100);
    expect(appraisalScore(weights, [1, 1, 1, 1, 1, 1])).toBe(20);
  });

  it('has no score until every competency has a rating from 1 to 5', () => {
    expect(appraisalScore(weights, [4, 4, 4, 4, 4, null])).toBeNull();
    expect(appraisalScore(weights, [4, 4, 4, 4, 4, 6])).toBeNull();
    expect(appraisalScore(weights, [4, 4, 4, 4, 4, 0])).toBeNull();
    expect(appraisalScore(weights, [4, 4, 4])).toBeNull();
    expect(appraisalScore([], [])).toBeNull();
  });

  it('keeps fractional weights exact to the hundredth', () => {
    expect(appraisalScore([33.33, 33.33, 33.34], [3, 3, 3])).toBe(60);
  });
});

describe('competency template parsing (FR-D14)', () => {
  it('accepts weights that sum to exactly 100', () => {
    const r = parseCompetencies('Subject knowledge | 25\nPlanning | 20\nClassroom | 20\nAssessment | 15\nProfessionalism | 10\nCommunication | 10');
    expect(r.errors).toEqual([]);
    expect(r.items).toHaveLength(6);
    expect(r.sumPct).toBe(100);
  });

  it('refuses a template whose weights do not sum to 100 and says what they sum to', () => {
    const r = parseCompetencies('A | 25\nB | 20\nC | 20\nD | 15\nE | 10\nF | 9');
    expect(r.sumPct).toBe(99);
    expect(r.errors).toEqual(['The weights add up to 99, not 100.']);
  });

  it('adds fractional weights without floating point drift', () => {
    expect(parseCompetencies('A | 33.33\nB | 33.33\nC | 33.34').errors).toEqual([]);
    expect(parseCompetencies('A | 0.1\nB | 0.2\nC | 99.7').errors).toEqual([]);
  });

  it('reports unreadable lines and empty templates', () => {
    expect(parseCompetencies('just words').errors[0]).toContain('Line 1');
    expect(parseCompetencies('A | 0').errors[0]).toContain('above 0');
    expect(parseCompetencies('   ').errors).toEqual(['Add at least one competency.']);
  });
});

describe('service-length eligibility (FR-D14)', () => {
  it('a joiner with 45 days of service at cycle close is below a 90 day minimum', () => {
    expect(serviceDays('2026-08-16', '2026-09-30')).toBe(45);
    expect(isEligible('2026-08-16', '2026-09-30', 90)).toBe(false);
  });

  it('exactly the minimum is eligible', () => {
    expect(isEligible('2026-07-02', '2026-09-30', 90)).toBe(true);
    expect(isEligible('2026-07-03', '2026-09-30', 90)).toBe(false);
  });
});
