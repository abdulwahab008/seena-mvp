import { and, count, eq, gte, sql } from 'drizzle-orm';
import { db, schema } from './db';

/**
 * Per-org monthly cost guard. Two limits, whichever hits first:
 *  - exam count (teacher-facing: "X / 100 exams this month")
 *  - hard USD cap across ALL LLM calls (backstop against regenerate spam / OCR)
 *
 * Usage is derived from data we already write — `exams` rows and the
 * `generations` telemetry table — so there's no separate counter to keep in sync.
 */

export type ExamQuota = {
  used: number;
  limit: number;
  remaining: number;
  costUsd: number;
  costCapUsd: number;
  exceeded: boolean;
  reason: 'exam_count' | 'cost_cap' | null;
};

function startOfMonthUTC(): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
}

export async function getExamQuota(orgId: string): Promise<ExamQuota> {
  const monthStart = startOfMonthUTC();

  const [org] = await db
    .select({
      limit: schema.organizations.monthlyExamLimit,
      cap: schema.organizations.monthlyCostCapUsd,
    })
    .from(schema.organizations)
    .where(eq(schema.organizations.id, orgId));
  const limit = org?.limit ?? 100;
  const costCapUsd = Number(org?.cap ?? 15);

  const [examRow] = await db
    .select({ n: count() })
    .from(schema.exams)
    .where(and(eq(schema.exams.orgId, orgId), gte(schema.exams.createdAt, monthStart)));
  const used = Number(examRow?.n ?? 0);

  const [costRow] = await db
    .select({ total: sql<string>`coalesce(sum(${schema.generations.costUsd}), 0)` })
    .from(schema.generations)
    .where(and(eq(schema.generations.orgId, orgId), gte(schema.generations.createdAt, monthStart)));
  const costUsd = Number(costRow?.total ?? 0);

  const reason: ExamQuota['reason'] =
    used >= limit ? 'exam_count' : costUsd >= costCapUsd ? 'cost_cap' : null;

  return {
    used,
    limit,
    remaining: Math.max(0, limit - used),
    costUsd,
    costCapUsd,
    exceeded: reason !== null,
    reason,
  };
}

export class QuotaExceededError extends Error {
  quota: ExamQuota;
  constructor(quota: ExamQuota) {
    const msg =
      quota.reason === 'cost_cap'
        ? `Monthly cost cap reached ($${quota.costUsd.toFixed(2)} / $${quota.costCapUsd}). Resets on the 1st.`
        : `Monthly exam limit reached (${quota.used} / ${quota.limit} exams). Resets on the 1st.`;
    super(msg);
    this.name = 'QuotaExceededError';
    this.quota = quota;
  }
}

/** Throws QuotaExceededError if the org is over either limit. Returns the quota otherwise. */
export async function assertExamQuota(orgId: string): Promise<ExamQuota> {
  const q = await getExamQuota(orgId);
  if (q.exceeded) throw new QuotaExceededError(q);
  return q;
}
