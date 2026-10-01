/**
 * FR-D14 - pure scoring helpers. The database is the authority (release_appraisal computes the stored
 * score from the weights frozen on the appraisal); these mirror it so the form can preview a score and
 * the template editor can check its weights before the round trip.
 */
export type Competency = { name: string; weightPct: number };

/** Exact 2-decimal arithmetic in hundredths, so 25 + 20 + 20 + 15 + 10 + 10 is exactly 100. */
const hundredths = (n: number) => Math.round(n * 100);

export type ParsedCompetencies = { items: Competency[]; sumPct: number; errors: string[] };

/** "Subject knowledge | 25" per line -> competencies, with the problems found. */
export function parseCompetencies(text: string): ParsedCompetencies {
  const errors: string[] = [];
  const items: Competency[] = [];
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  lines.forEach((line, i) => {
    const m = /^(.+?)\s*[|,:]\s*(\d{1,3}(?:\.\d{1,2})?)\s*%?$/.exec(line);
    if (!m) {
      errors.push(`Line ${i + 1}: write the competency, then its weight, like "Classroom management | 20".`);
      return;
    }
    const weightPct = Number(m[2]);
    if (weightPct <= 0 || weightPct > 100) {
      errors.push(`Line ${i + 1}: a weight must be above 0 and at most 100.`);
      return;
    }
    items.push({ name: m[1]!.trim(), weightPct });
  });
  if (items.length === 0 && errors.length === 0) errors.push('Add at least one competency.');
  const sumPct = items.reduce((s, c) => s + hundredths(c.weightPct), 0) / 100;
  if (items.length > 0 && hundredths(sumPct) !== 10000) errors.push(`The weights add up to ${sumPct}, not 100.`);
  return { items, sumPct, errors };
}

/** sum(weight x rating / 5) rounded to 2 decimals, or null while any rating is missing or out of range. */
export function appraisalScore(weights: readonly number[], ratings: readonly (number | null | undefined)[]): number | null {
  if (weights.length === 0 || ratings.length !== weights.length) return null;
  let sum = 0;
  for (let i = 0; i < weights.length; i += 1) {
    const r = ratings[i];
    if (r === null || r === undefined || !Number.isInteger(r) || r < 1 || r > 5) return null;
    sum += hundredths(weights[i]!) * r;
  }
  return Math.round(sum / 5) / 100;
}

/** Whole days of service at a date: the eligibility figure the cycle compares with its minimum. */
export function serviceDays(doj: string, on: string): number {
  return Math.round((new Date(`${on}T00:00:00Z`).getTime() - new Date(`${doj}T00:00:00Z`).getTime()) / 86_400_000);
}

export function isEligible(doj: string, cycleClosesOn: string, minServiceDays: number): boolean {
  return serviceDays(doj, cycleClosesOn) >= minServiceDays;
}
