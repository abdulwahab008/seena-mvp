import { and, desc, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { ChatPanel } from '@/components/chat/chat-panel';
import { ALL_PATTERNS } from '@seena/shared/patterns';

export default async function ChatPage() {
  const { orgId } = await requireSession();
  const books = await db
    .select({
      id: schema.books.id,
      title: schema.books.title,
      subject: schema.books.subject,
      grade: schema.books.grade,
      board: schema.books.board,
      status: schema.books.status,
    })
    .from(schema.books)
    .where(eq(schema.books.orgId, orgId));

  const customRows = await db
    .select({
      id: schema.customPatterns.id,
      name: schema.customPatterns.name,
      format: schema.customPatterns.format,
      board: schema.customPatterns.board,
    })
    .from(schema.customPatterns)
    .where(
      and(
        eq(schema.customPatterns.orgId, orgId),
        eq(schema.customPatterns.archived, false),
      ),
    )
    .orderBy(desc(schema.customPatterns.updatedAt));

  const patterns = [
    ...ALL_PATTERNS.map((p) => ({
      id: p.id,
      name: p.name,
      format: p.format,
      board: p.board,
      kind: 'builtIn' as const,
    })),
    ...customRows.map((p) => ({
      id: p.id,
      name: p.name,
      format: p.format,
      board: p.board,
      kind: 'custom' as const,
    })),
  ];

  return (
    <div className="mx-auto max-w-3xl">
      <h1 className="mb-4 text-2xl font-semibold">Generate an exam</h1>
      <ChatPanel books={books} patterns={patterns} />
    </div>
  );
}
