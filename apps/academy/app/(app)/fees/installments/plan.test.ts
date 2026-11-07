import { describe, expect, it } from 'vitest';
import { splitPlan } from './plan';

describe('splitPlan', () => {
  it('splits into whole-rupee monthly parts and puts the remainder on the last', () => {
    const plan = splitPlan(1000050, 3, '2026-01-31');
    expect(plan.map((p) => p.amount_paisa)).toEqual([333300, 333300, 333450]);
    expect(plan.reduce((s, p) => s + p.amount_paisa, 0)).toBe(1000050);
    expect(plan.map((p) => p.due_date)).toEqual(['2026-01-31', '2026-02-28', '2026-03-31']);
  });
});
