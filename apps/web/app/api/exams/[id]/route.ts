import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { apiError } from '@/lib/http';
import { Exam } from '@seena/shared';

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;
  const [exam] = await db
    .select()
    .from(schema.exams)
    .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
  if (!exam) return NextResponse.json({ error: 'not found' }, { status: 404 });
  return NextResponse.json({ exam });
}

const PatchBody = z.object({
  title: z.string().min(1).optional(),
  payload: Exam.optional(),
  status: z.enum(['draft', 'finalized', 'archived']).optional(),
});

export async function PATCH(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    const { id } = await params;
    const body = PatchBody.parse(await req.json());

    const [exam] = await db
      .select()
      .from(schema.exams)
      .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
    if (!exam) return NextResponse.json({ error: 'not found' }, { status: 404 });

    const [updated] = await db
      .update(schema.exams)
      .set({
        title: body.title ?? exam.title,
        payload: body.payload ?? exam.payload,
        totalMarks: body.payload?.total_marks ?? exam.totalMarks,
        status: body.status ?? exam.status,
        updatedAt: new Date(),
      })
      .where(eq(schema.exams.id, id))
      .returning();

    return NextResponse.json({ exam: updated });
  } catch (e) {
    return apiError(e);
  }
}

export async function DELETE(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;
  const [exam] = await db
    .select()
    .from(schema.exams)
    .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
  if (!exam) return NextResponse.json({ error: 'not found' }, { status: 404 });
  await db.delete(schema.exams).where(eq(schema.exams.id, id));
  return NextResponse.json({ ok: true });
}
