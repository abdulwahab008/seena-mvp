import { NextResponse } from 'next/server';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { apiError } from '@/lib/http';

export async function DELETE(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    const { id } = await params;
    const [row] = await db
      .select({ id: schema.bankQuestions.id })
      .from(schema.bankQuestions)
      .where(and(eq(schema.bankQuestions.id, id), eq(schema.bankQuestions.orgId, orgId)));
    if (!row) return NextResponse.json({ error: 'not found' }, { status: 404 });
    await db.delete(schema.bankQuestions).where(eq(schema.bankQuestions.id, id));
    return NextResponse.json({ ok: true });
  } catch (e) {
    return apiError(e);
  }
}
