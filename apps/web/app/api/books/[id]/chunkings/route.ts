import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, desc, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { bookRechunkQueue } from '@/lib/queue';
import {
  CHUNK_STRATEGIES,
  EMBEDDING_MODELS,
  DEFAULT_EMBEDDING_MODEL_KEY,
  resolveStrategyConfig,
  type StrategyKey,
  type EmbeddingModelKey,
} from '@seena/shared/rag/strategies';
import { pineconeNamespace } from '@seena/shared/rag/namespace';

const STRATEGY_KEYS = Object.keys(CHUNK_STRATEGIES) as [StrategyKey, ...StrategyKey[]];
const EMBEDDING_MODEL_KEYS = Object.keys(EMBEDDING_MODELS) as [
  EmbeddingModelKey,
  ...EmbeddingModelKey[],
];

const CreateBody = z.object({
  strategy: z.enum(STRATEGY_KEYS),
  embeddingModel: z.enum(EMBEDDING_MODEL_KEYS).optional(),
  setDefault: z.boolean().optional(),
});

// Pinecone index dimension constraint. The current `seena-exams` index is
// 3072-d; if we ever introduce a second index this should be promoted to env.
const PINECONE_INDEX_DIMENSION = 3072;

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    const { id: bookId } = await params;

    const [book] = await db
      .select({ id: schema.books.id })
      .from(schema.books)
      .where(and(eq(schema.books.id, bookId), eq(schema.books.orgId, orgId)));
    if (!book) return NextResponse.json({ error: 'not found' }, { status: 404 });

    const rows = await db
      .select()
      .from(schema.chunkings)
      .where(and(eq(schema.chunkings.bookId, bookId), eq(schema.chunkings.orgId, orgId)))
      .orderBy(desc(schema.chunkings.createdAt));

    return NextResponse.json({
      chunkings: rows.map((c) => ({
        id: c.id,
        strategy: c.strategy,
        strategyConfig: c.strategyConfig,
        embeddingModel: c.embeddingModel,
        embeddingDimensions: c.embeddingDimensions,
        namespace: c.namespace,
        chunkCount: c.chunkCount,
        status: c.status,
        isDefault: c.isDefault,
        failureReason: c.failureReason,
        createdAt: c.createdAt,
        readyAt: c.readyAt,
      })),
    });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    const { id: bookId } = await params;

    const [book] = await db
      .select({ id: schema.books.id })
      .from(schema.books)
      .where(and(eq(schema.books.id, bookId), eq(schema.books.orgId, orgId)));
    if (!book) return NextResponse.json({ error: 'not found' }, { status: 404 });

    const body = CreateBody.parse(await req.json());

    if (!(body.strategy in CHUNK_STRATEGIES)) {
      return NextResponse.json({ error: `unknown strategy: ${body.strategy}` }, { status: 400 });
    }

    const embeddingModel: EmbeddingModelKey = body.embeddingModel ?? DEFAULT_EMBEDDING_MODEL_KEY;
    const modelMeta = EMBEDDING_MODELS[embeddingModel];
    if (!modelMeta) {
      return NextResponse.json(
        { error: `unknown embedding model: ${embeddingModel}` },
        { status: 400 },
      );
    }

    if (modelMeta.dimensions !== PINECONE_INDEX_DIMENSION) {
      return NextResponse.json(
        {
          error: `embedding model ${embeddingModel} has ${modelMeta.dimensions} dimensions but the Pinecone index is configured for ${PINECONE_INDEX_DIMENSION}. Use a matching model or provision a new index.`,
        },
        { status: 400 },
      );
    }

    const strategyConfig = resolveStrategyConfig(body.strategy);
    const namespace = pineconeNamespace(orgId, embeddingModel);

    const [chunking] = await db
      .insert(schema.chunkings)
      .values({
        bookId,
        orgId,
        strategy: body.strategy,
        strategyConfig,
        embeddingModel,
        embeddingDimensions: modelMeta.dimensions,
        namespace,
        status: 'pending',
        isDefault: false,
      })
      .returning();
    if (!chunking) throw new Error('failed to insert chunking');

    await bookRechunkQueue().add(
      'process',
      { chunkingId: chunking.id, bookId, orgId },
      { attempts: 1, removeOnComplete: true, removeOnFail: 100 },
    );

    return NextResponse.json({
      chunking: {
        id: chunking.id,
        strategy: chunking.strategy,
        strategyConfig: chunking.strategyConfig,
        embeddingModel: chunking.embeddingModel,
        embeddingDimensions: chunking.embeddingDimensions,
        namespace: chunking.namespace,
        chunkCount: chunking.chunkCount,
        status: chunking.status,
        isDefault: chunking.isDefault,
        failureReason: chunking.failureReason,
        createdAt: chunking.createdAt,
        readyAt: chunking.readyAt,
      },
    });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
