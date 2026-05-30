import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, desc, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { gradeSubmissionQueue } from '@/lib/queue';

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;

  const [exam] = await db
    .select({ id: schema.exams.id })
    .from(schema.exams)
    .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
  if (!exam) return NextResponse.json({ error: 'not found' }, { status: 404 });

  const rows = await db
    .select({
      id: schema.submissions.id,
      studentName: schema.submissions.studentName,
      status: schema.submissions.status,
      totalMarks: schema.submissions.totalMarks,
      obtainedMarks: schema.submissions.obtainedMarks,
      createdAt: schema.submissions.createdAt,
      gradedAt: schema.submissions.gradedAt,
    })
    .from(schema.submissions)
    .where(and(eq(schema.submissions.examId, id), eq(schema.submissions.orgId, orgId)))
    .orderBy(desc(schema.submissions.createdAt));

  return NextResponse.json({ submissions: rows });
}

const CreateBody = z.object({
  studentName: z.string().min(1).optional(),
  storageKey: z.string().min(1),
});

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { userId, orgId } = await requireSession();
    const { id } = await params;
    const body = CreateBody.parse(await req.json());

    const [exam] = await db
      .select({ id: schema.exams.id })
      .from(schema.exams)
      .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
    if (!exam) return NextResponse.json({ error: 'not found' }, { status: 404 });

    const [submission] = await db
      .insert(schema.submissions)
      .values({
        orgId,
        examId: id,
        createdBy: userId,
        studentName: body.studentName ?? null,
        storageKey: body.storageKey,
        status: 'pending',
      })
      .returning();
    if (!submission) throw new Error('failed to insert submission');

    await gradeSubmissionQueue().add(
      'grade',
      { submissionId: submission.id, examId: id, orgId },
      { attempts: 1, removeOnComplete: true, removeOnFail: 100 },
    );

    return NextResponse.json({ submission });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
