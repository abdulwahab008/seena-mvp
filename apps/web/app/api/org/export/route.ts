import { NextResponse } from 'next/server';
import { eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { apiError } from '@/lib/http';

export async function GET() {
  try {
    const { orgId, role } = await requireSession();
    if (role !== 'admin') {
      return NextResponse.json(
        { error: 'Only an admin can export organization data.' },
        { status: 403 },
      );
    }

    const [org, books, exams, submissions, patterns, bank] = await Promise.all([
      db.select().from(schema.organizations).where(eq(schema.organizations.id, orgId)),
      db.select().from(schema.books).where(eq(schema.books.orgId, orgId)),
      db.select().from(schema.exams).where(eq(schema.exams.orgId, orgId)),
      db.select().from(schema.submissions).where(eq(schema.submissions.orgId, orgId)),
      db.select().from(schema.customPatterns).where(eq(schema.customPatterns.orgId, orgId)),
      db.select().from(schema.bankQuestions).where(eq(schema.bankQuestions.orgId, orgId)),
    ]);

    const body = JSON.stringify(
      {
        exportedAt: new Date().toISOString(),
        org: org[0] ?? null,
        books,
        exams,
        submissions,
        patterns,
        bank,
      },
      null,
      2,
    );

    return new NextResponse(body, {
      headers: {
        'content-type': 'application/json',
        'content-disposition': `attachment; filename="seena-export-${orgId}.json"`,
      },
    });
  } catch (e) {
    return apiError(e);
  }
}
