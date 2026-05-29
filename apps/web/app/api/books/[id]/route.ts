import { NextResponse } from 'next/server';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { index } from '@/lib/pinecone';

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;
  const [book] = await db
    .select()
    .from(schema.books)
    .where(and(eq(schema.books.id, id), eq(schema.books.orgId, orgId)));
  if (!book) return NextResponse.json({ error: 'not found' }, { status: 404 });
  return NextResponse.json({ book });
}

export async function DELETE(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;
  const [book] = await db
    .select()
    .from(schema.books)
    .where(and(eq(schema.books.id, id), eq(schema.books.orgId, orgId)));
  if (!book) return NextResponse.json({ error: 'not found' }, { status: 404 });

  // Best-effort vector cleanup. Vectors for a book may live across multiple
  // namespaces (one per chunking). Look up each chunking's namespace and
  // delete by bookId in that namespace.
  try {
    const chunkings = await db
      .select({ namespace: schema.chunkings.namespace })
      .from(schema.chunkings)
      .where(and(eq(schema.chunkings.bookId, id), eq(schema.chunkings.orgId, orgId)));
    const seen = new Set<string>();
    const ix = index();
    for (const c of chunkings) {
      if (seen.has(c.namespace)) continue;
      seen.add(c.namespace);
      try {
        await ix.namespace(c.namespace).deleteMany({ filter: { bookId: id } });
      } catch (e) {
        console.warn(`pinecone delete failed for namespace ${c.namespace} (non-fatal)`, e);
      }
    }
  } catch (e) {
    console.warn('pinecone delete failed (non-fatal)', e);
  }

  await db.delete(schema.books).where(eq(schema.books.id, id));
  return NextResponse.json({ ok: true });
}
