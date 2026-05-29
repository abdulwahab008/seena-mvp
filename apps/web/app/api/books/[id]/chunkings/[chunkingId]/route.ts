import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, eq, ne } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { index } from '@/lib/pinecone';

const PatchBody = z.object({
  isDefault: z.literal(true),
});

type RouteParams = { id: string; chunkingId: string };

async function loadChunking(orgId: string, bookId: string, chunkingId: string) {
  const [row] = await db
    .select()
    .from(schema.chunkings)
    .where(
      and(
        eq(schema.chunkings.id, chunkingId),
        eq(schema.chunkings.bookId, bookId),
        eq(schema.chunkings.orgId, orgId),
      ),
    );
  return row ?? null;
}

export async function PATCH(req: Request, { params }: { params: Promise<RouteParams> }) {
  try {
    const { orgId } = await requireSession();
    const { id: bookId, chunkingId } = await params;
    const body = PatchBody.parse(await req.json());

    const chunking = await loadChunking(orgId, bookId, chunkingId);
    if (!chunking) return NextResponse.json({ error: 'not found' }, { status: 404 });

    if (body.isDefault) {
      if (chunking.status !== 'ready') {
        return NextResponse.json(
          { error: `cannot promote: chunking status is ${chunking.status}, not ready` },
          { status: 400 },
        );
      }
      const updated = await db.transaction(async (tx) => {
        await tx
          .update(schema.chunkings)
          .set({ isDefault: false })
          .where(
            and(
              eq(schema.chunkings.bookId, bookId),
              eq(schema.chunkings.orgId, orgId),
              ne(schema.chunkings.id, chunkingId),
            ),
          );
        const [row] = await tx
          .update(schema.chunkings)
          .set({ isDefault: true })
          .where(eq(schema.chunkings.id, chunkingId))
          .returning();
        return row;
      });
      if (!updated) throw new Error('failed to update chunking');
      return NextResponse.json({
        chunking: {
          id: updated.id,
          strategy: updated.strategy,
          strategyConfig: updated.strategyConfig,
          embeddingModel: updated.embeddingModel,
          embeddingDimensions: updated.embeddingDimensions,
          namespace: updated.namespace,
          chunkCount: updated.chunkCount,
          status: updated.status,
          isDefault: updated.isDefault,
          failureReason: updated.failureReason,
          createdAt: updated.createdAt,
          readyAt: updated.readyAt,
        },
      });
    }

    return NextResponse.json({ error: 'no-op' }, { status: 400 });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}

export async function DELETE(_req: Request, { params }: { params: Promise<RouteParams> }) {
  try {
    const { orgId } = await requireSession();
    const { id: bookId, chunkingId } = await params;

    const chunking = await loadChunking(orgId, bookId, chunkingId);
    if (!chunking) return NextResponse.json({ error: 'not found' }, { status: 404 });

    if (chunking.isDefault) {
      return NextResponse.json(
        { error: 'cannot delete the default chunking. Promote another chunking first.' },
        { status: 400 },
      );
    }

    const siblings = await db
      .select({ id: schema.chunkings.id })
      .from(schema.chunkings)
      .where(and(eq(schema.chunkings.bookId, bookId), eq(schema.chunkings.orgId, orgId)));
    if (siblings.length <= 1) {
      return NextResponse.json(
        { error: 'cannot delete the only chunking. A book needs at least one.' },
        { status: 400 },
      );
    }

    try {
      await index()
        .namespace(chunking.namespace)
        .deleteMany({ filter: { bookId, chunkingId } });
    } catch (e) {
      console.warn(`pinecone delete failed for chunking ${chunkingId} (non-fatal)`, e);
    }

    await db.delete(schema.chunkings).where(eq(schema.chunkings.id, chunkingId));
    return NextResponse.json({ ok: true });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
