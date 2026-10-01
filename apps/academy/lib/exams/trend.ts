/**
 * FR-J06. Turns v_student_subject_trend rows into the series a chart plots.
 *
 * Kept free of React and of the database so the three rules the acceptance
 * criteria care about are testable on their own:
 *   - the child's points and the section averages share one axis (0-100);
 *   - a suppressed average is absent (null), never drawn as zero;
 *   - a term with no result is absent from the series, never drawn as zero.
 */
export type TrendRow = {
  subject_id: string | null;
  subject_name: string | null;
  exam_term_id: string | null;
  term_name: string | null;
  term_sequence: number | null;
  pct: number | null;
  section_avg_pct: number | null;
  comparison_suppressed: boolean | null;
  comparison_note: string | null;
};

export type TrendPoint = {
  termId: string;
  termName: string;
  sequence: number;
  pct: number;
  /** Null when the section has too few ranked candidates to compare. */
  sectionAvg: number | null;
};

export type SubjectTrend = {
  subjectId: string;
  subjectName: string;
  points: TrendPoint[];
  /** Set when any point's average was suppressed; the text to show instead. */
  suppressedNote: string | null;
  /** improving / slipping / steady, from the first to the last point. */
  direction: 'improving' | 'slipping' | 'steady' | 'single';
};

export const TOO_FEW = 'too few students to compare';

export function groupTrend(rows: TrendRow[]): SubjectTrend[] {
  const bySubject = new Map<string, SubjectTrend>();
  for (const r of rows) {
    if (!r.subject_id || !r.exam_term_id || r.pct === null || r.pct === undefined) continue;
    let s = bySubject.get(r.subject_id);
    if (!s) {
      s = { subjectId: r.subject_id, subjectName: r.subject_name ?? '', points: [], suppressedNote: null, direction: 'single' };
      bySubject.set(r.subject_id, s);
    }
    s.points.push({
      termId: r.exam_term_id,
      termName: r.term_name ?? '',
      sequence: r.term_sequence ?? 0,
      pct: Number(r.pct),
      sectionAvg: r.section_avg_pct === null || r.section_avg_pct === undefined ? null : Number(r.section_avg_pct),
    });
    if (r.comparison_suppressed) s.suppressedNote = r.comparison_note ?? TOO_FEW;
  }
  const out = [...bySubject.values()];
  for (const s of out) {
    s.points.sort((a, b) => a.sequence - b.sequence);
    s.direction = directionOf(s.points);
  }
  return out.sort((a, b) => a.subjectName.localeCompare(b.subjectName));
}

/** Within 2 points of where it started is steady: noise is not a trend. */
export function directionOf(points: TrendPoint[]): SubjectTrend['direction'] {
  if (points.length < 2) return 'single';
  const delta = points[points.length - 1]!.pct - points[0]!.pct;
  if (delta > 2) return 'improving';
  if (delta < -2) return 'slipping';
  return 'steady';
}

export type ChartGeometry = {
  width: number;
  height: number;
  own: { x: number; y: number; pct: number; label: string }[];
  /** One polyline per run of consecutive non-null averages. */
  avgRuns: { x: number; y: number }[][];
  yTicks: { y: number; label: string }[];
};

/** A fixed 0-100 axis shared by both series (AC1: "on the same axis"). */
export function chartGeometry(points: TrendPoint[], width = 360, height = 180): ChartGeometry {
  const pad = { l: 34, r: 12, t: 10, b: 26 };
  const innerW = width - pad.l - pad.r;
  const innerH = height - pad.t - pad.b;
  const x = (i: number) => pad.l + (points.length <= 1 ? innerW / 2 : (innerW * i) / (points.length - 1));
  const y = (pct: number) => pad.t + innerH - (Math.max(0, Math.min(100, pct)) / 100) * innerH;

  const own = points.map((p, i) => ({ x: x(i), y: y(p.pct), pct: p.pct, label: p.termName }));
  const avgRuns: { x: number; y: number }[][] = [];
  let run: { x: number; y: number }[] = [];
  points.forEach((p, i) => {
    if (p.sectionAvg === null) {
      if (run.length) avgRuns.push(run);
      run = [];
    } else {
      run.push({ x: x(i), y: y(p.sectionAvg) });
    }
  });
  if (run.length) avgRuns.push(run);

  const yTicks = [0, 25, 50, 75, 100].map((v) => ({ y: y(v), label: String(v) }));
  return { width, height, own, avgRuns, yTicks };
}
