import { NextResponse } from 'next/server';
import { eq, desc } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';

export async function GET() {
  const { orgId } = await requireSession();
  const rows = await db
    .select({
      id: schema.exams.id,
      title: schema.exams.title,
      patternId: schema.exams.patternId,
      totalMarks: schema.exams.totalMarks,
      bookId: schema.exams.bookId,
      status: schema.exams.status,
      createdAt: schema.exams.createdAt,
    })
    .from(schema.exams)
    .where(eq(schema.exams.orgId, orgId))
    .orderBy(desc(schema.exams.createdAt))
    .limit(100);
  return NextResponse.json({ exams: rows });
}
