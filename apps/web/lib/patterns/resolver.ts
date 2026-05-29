import { and, eq } from 'drizzle-orm';
import {
  ALL_PATTERNS,
  getPattern,
  scorePattern,
  type PatternSection,
  type PatternSpec,
  type Format,
  type Board,
} from '@seena/shared';
import { db, schema } from '@/lib/db';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const SCORE_THRESHOLD = 4;

export type ResolvePatternOpts = {
  patternId?: string | null;
  format?: Format | null;
  board?: Board | string | null;
  grade?: number | null;
  subject?: string | null;
};

export type CustomPatternRow = typeof schema.customPatterns.$inferSelect;

export function customRowToSpec(row: CustomPatternRow): PatternSpec {
  return {
    id: row.id,
    name: row.name,
    board: row.board as Board,
    format: row.format as Format,
    grade: row.grade,
    subject: row.subject,
    totalMarks: row.totalMarks,
    sections: row.sections as PatternSection[],
    notes: row.notes ?? undefined,
  };
}

export async function resolvePattern(
  orgId: string,
  opts: ResolvePatternOpts,
): Promise<PatternSpec | null> {
  const { patternId } = opts;

  if (patternId && UUID_RE.test(patternId)) {
    const [row] = await db
      .select()
      .from(schema.customPatterns)
      .where(
        and(
          eq(schema.customPatterns.id, patternId),
          eq(schema.customPatterns.orgId, orgId),
          eq(schema.customPatterns.archived, false),
        ),
      );
    if (row) return customRowToSpec(row);
    // UUID lookup miss — fall through to scoring fallback rather than fail.
  } else if (patternId) {
    const builtin = getPattern(patternId);
    if (builtin) return builtin;
    // Hallucinated/unknown id (the LLM sometimes invents one) — fall through
    // to scoring on format/board/grade/subject.
    console.warn(`[resolvePattern] unknown patternId "${patternId}", falling back to scoring`);
  }

  const target = {
    board: (opts.board ?? undefined) as PatternSpec['board'] | undefined,
    format: (opts.format ?? undefined) as PatternSpec['format'] | undefined,
    grade: opts.grade ?? undefined,
    subject: opts.subject ?? undefined,
  };

  const customRows = await db
    .select()
    .from(schema.customPatterns)
    .where(
      and(
        eq(schema.customPatterns.orgId, orgId),
        eq(schema.customPatterns.archived, false),
      ),
    );

  const candidates: PatternSpec[] = [...ALL_PATTERNS, ...customRows.map(customRowToSpec)];

  let best: PatternSpec | null = null;
  let bestScore = SCORE_THRESHOLD - 1;
  for (const p of candidates) {
    const s = scorePattern(p, target);
    if (s > bestScore) {
      best = p;
      bestScore = s;
    }
  }
  return best;
}
