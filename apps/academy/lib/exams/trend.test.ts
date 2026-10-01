import { describe, expect, it } from 'vitest';
import { chartGeometry, directionOf, groupTrend, TOO_FEW, type TrendRow } from './trend';

/** FR-J06. The series the chart plots, away from the database and the DOM. */
const row = (over: Partial<TrendRow>): TrendRow => ({
  subject_id: 'chem',
  subject_name: 'Chemistry',
  exam_term_id: 't1',
  term_name: 'First Term',
  term_sequence: 1,
  pct: 62,
  section_avg_pct: 58,
  comparison_suppressed: false,
  comparison_note: null,
  ...over,
});

const chemistry: TrendRow[] = [
  row({}),
  row({ exam_term_id: 't2', term_name: 'Mid Term', term_sequence: 2, pct: 55, section_avg_pct: 60 }),
  row({ exam_term_id: 't3', term_name: 'Final Term', term_sequence: 3, pct: 71, section_avg_pct: 64 }),
];

describe('groupTrend', () => {
  it('AC1: three points beside three section averages, in term order', () => {
    const [s] = groupTrend([chemistry[2]!, chemistry[0]!, chemistry[1]!]);
    expect(s!.points.map((p) => p.pct)).toEqual([62, 55, 71]);
    expect(s!.points.map((p) => p.sectionAvg)).toEqual([58, 60, 64]);
    expect(s!.points.map((p) => p.termName)).toEqual(['First Term', 'Mid Term', 'Final Term']);
    expect(s!.suppressedNote).toBeNull();
  });

  it('AC2: a suppressed average stays null and the note says why', () => {
    const [s] = groupTrend(
      chemistry.map((r) => ({ ...r, section_avg_pct: null, comparison_suppressed: true, comparison_note: TOO_FEW })),
    );
    expect(s!.points.every((p) => p.sectionAvg === null)).toBe(true);
    expect(s!.suppressedNote).toBe('too few students to compare');
  });

  it('AC4: a term without a result is omitted, not plotted as zero', () => {
    const [s] = groupTrend([chemistry[0]!, row({ exam_term_id: 't2', term_sequence: 2, pct: null }), chemistry[2]!]);
    expect(s!.points).toHaveLength(2);
    expect(s!.points.some((p) => p.pct === 0)).toBe(false);
  });

  it('keeps subjects apart and sorted by name', () => {
    const out = groupTrend([row({ subject_id: 'phy', subject_name: 'Physics' }), row({})]);
    expect(out.map((s) => s.subjectName)).toEqual(['Chemistry', 'Physics']);
  });
});

describe('directionOf', () => {
  it('62 -> 71 is improving, 71 -> 55 is slipping, +-2 is steady, one point is single', () => {
    const p = (...v: number[]) => v.map((pct, i) => ({ termId: String(i), termName: '', sequence: i, pct, sectionAvg: null }));
    expect(directionOf(p(62, 55, 71))).toBe('improving');
    expect(directionOf(p(71, 60, 55))).toBe('slipping');
    expect(directionOf(p(60, 40, 61))).toBe('steady');
    expect(directionOf(p(60))).toBe('single');
  });
});

describe('chartGeometry', () => {
  const points = groupTrend(chemistry)[0]!.points;

  it('AC1: both series share one 0-100 axis', () => {
    const g = chartGeometry(points);
    // 71 is plotted above 64 on the same scale, and 55 below 60.
    expect(g.own[2]!.y).toBeLessThan(g.avgRuns[0]![2]!.y);
    expect(g.own[1]!.y).toBeGreaterThan(g.avgRuns[0]![1]!.y);
    expect(g.own.map((o) => o.x)).toEqual(g.avgRuns[0]!.map((a) => a.x));
  });

  it('draws no average line at all where every average is suppressed', () => {
    const g = chartGeometry(points.map((p) => ({ ...p, sectionAvg: null })));
    expect(g.avgRuns).toEqual([]);
    expect(g.own).toHaveLength(3);
  });

  it('breaks the average line across a gap instead of joining through it', () => {
    const g = chartGeometry([points[0]!, { ...points[1]!, sectionAvg: null }, points[2]!]);
    expect(g.avgRuns).toHaveLength(2);
  });

  it('places a single point mid-axis', () => {
    const g = chartGeometry([points[0]!]);
    expect(g.own).toHaveLength(1);
    expect(g.own[0]!.x).toBeGreaterThan(100);
  });
});
