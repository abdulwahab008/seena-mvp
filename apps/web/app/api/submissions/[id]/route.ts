import { NextResponse } from 'next/server';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import { GradedResult } from '@seena/shared';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { deleteObject } from '@/lib/storage';
import { apiError } from '@/lib/http';

const ReviewBody = z.object({ result: GradedResult });

// Clamp teacher edits to valid bounds and recompute totals server-side —
// never trust client-sent totals.
function normalizeReviewed(result: z.infer<typeof GradedResult>): z.infer<typeof GradedResult> {
  const questions = result.questions.map((q) => ({
    ...q,
    awarded: Math.min(Math.max(q.awarded, 0), q.max),
  }));
  const totalMax = questions.reduce((s, q) => s + q.max, 0);
  const totalAwarded = questions.reduce((s, q) => s + q.awarded, 0);
  const percentage = totalMax > 0 ? (totalAwarded / totalMax) * 100 : 0;
  return { ...result, questions, totalMax, totalAwarded, percentage };
}

export async function PATCH(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { userId, orgId } = await requireSession();
    const { id } = await params;
    const [submission] = await db
      .select({ id: schema.submissions.id, status: schema.submissions.status })
      .from(schema.submissions)
      .where(and(eq(schema.submissions.id, id), eq(schema.submissions.orgId, orgId)));
    if (!submission) return NextResponse.json({ error: 'not found' }, { status: 404 });
    if (submission.status !== 'graded') {
      return NextResponse.json({ error: 'Only graded submissions can be reviewed.' }, { status: 400 });
    }

    const body = ReviewBody.parse(await req.json());
    const reviewed = normalizeReviewed(body.result);

    const [updated] = await db
      .update(schema.submissions)
      .set({
        reviewedResult: reviewed,
        reviewedBy: userId,
        reviewedAt: new Date(),
        obtainedMarks: reviewed.totalAwarded.toFixed(2),
      })
      .where(eq(schema.submissions.id, id))
      .returning();
    return NextResponse.json({ submission: updated });
  } catch (e) {
    return apiError(e);
  }
}

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;
  const [submission] = await db
    .select()
    .from(schema.submissions)
    .where(and(eq(schema.submissions.id, id), eq(schema.submissions.orgId, orgId)));
  if (!submission) return NextResponse.json({ error: 'not found' }, { status: 404 });
  return NextResponse.json({ submission });
}

export async function DELETE(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;
  const [submission] = await db
    .select({ id: schema.submissions.id, storageKey: schema.submissions.storageKey })
    .from(schema.submissions)
    .where(and(eq(schema.submissions.id, id), eq(schema.submissions.orgId, orgId)));
  if (!submission) return NextResponse.json({ error: 'not found' }, { status: 404 });
  // Remove the student answer-sheet PDF too, not just the DB row.
  try {
    await deleteObject(submission.storageKey);
  } catch (e) {
    console.warn('storage delete failed (non-fatal)', e);
  }
  await db.delete(schema.submissions).where(eq(schema.submissions.id, id));
  return NextResponse.json({ ok: true });
}
