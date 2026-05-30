import { NextResponse } from 'next/server';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';

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
    .select({ id: schema.submissions.id })
    .from(schema.submissions)
    .where(and(eq(schema.submissions.id, id), eq(schema.submissions.orgId, orgId)));
  if (!submission) return NextResponse.json({ error: 'not found' }, { status: 404 });
  await db.delete(schema.submissions).where(eq(schema.submissions.id, id));
  return NextResponse.json({ ok: true });
}
