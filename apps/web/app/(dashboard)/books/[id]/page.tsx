import Link from 'next/link';
import { notFound } from 'next/navigation';
import { and, desc, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { RechunkForm } from '@/components/book-detail/rechunk-form';
import { ChunkingsList, type ChunkingRow } from '@/components/book-detail/chunkings-list';

function bookStatusClass(status: string): string {
  switch (status) {
    case 'ready':
      return 'bg-green-100 text-green-800';
    case 'failed':
      return 'bg-red-100 text-red-800';
    case 'processing':
      return 'bg-blue-100 text-blue-800';
    case 'uploading':
    default:
      return 'bg-amber-100 text-amber-800';
  }
}

export default async function BookDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;

  const [book] = await db
    .select()
    .from(schema.books)
    .where(and(eq(schema.books.id, id), eq(schema.books.orgId, orgId)));
  if (!book) notFound();

  const chunkingRows = await db
    .select()
    .from(schema.chunkings)
    .where(and(eq(schema.chunkings.bookId, id), eq(schema.chunkings.orgId, orgId)))
    .orderBy(desc(schema.chunkings.createdAt));

  const chunkings: ChunkingRow[] = chunkingRows.map((c) => ({
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
  }));

  const recentExams = await db
    .select({
      id: schema.exams.id,
      title: schema.exams.title,
      patternId: schema.exams.patternId,
      totalMarks: schema.exams.totalMarks,
      status: schema.exams.status,
      createdAt: schema.exams.createdAt,
    })
    .from(schema.exams)
    .where(and(eq(schema.exams.bookId, id), eq(schema.exams.orgId, orgId)))
    .orderBy(desc(schema.exams.createdAt))
    .limit(5);

  return (
    <div className="space-y-8">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-1">
          <div className="text-xs text-muted-foreground">
            <Link href="/books" className="hover:underline">
              Books
            </Link>{' '}
            / {book.title}
          </div>
          <h1 className="text-2xl font-semibold">{book.title}</h1>
          <div className="flex flex-wrap items-center gap-3 text-sm text-muted-foreground">
            <span>{book.subject}</span>
            {book.grade != null ? <span>· Grade {book.grade}</span> : null}
            <span>· {book.board}</span>
            <span
              className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${bookStatusClass(book.status)}`}
            >
              {book.status}
              {book.status === 'ready' ? ` · ${book.chunkCount} chunks` : ''}
            </span>
          </div>
          {book.failureReason ? (
            <div className="text-xs text-red-600">{book.failureReason}</div>
          ) : null}
        </div>
      </div>

      <section className="space-y-3">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold">Chunkings</h2>
        </div>
        <ChunkingsList bookId={book.id} chunkings={chunkings} />
        <RechunkForm bookId={book.id} />
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Recent exams from this book</h2>
        {recentExams.length === 0 ? (
          <Card>
            <CardContent className="p-6 text-center text-sm text-muted-foreground">
              No exams generated from this book yet.
            </CardContent>
          </Card>
        ) : (
          <div className="grid gap-3 md:grid-cols-2">
            {recentExams.map((e) => (
              <Link key={e.id} href={`/exams/${e.id}`} className="block">
                <Card className="transition hover:bg-accent">
                  <CardHeader>
                    <CardTitle className="truncate text-base">{e.title}</CardTitle>
                  </CardHeader>
                  <CardContent className="text-sm">
                    <div>
                      <span className="text-muted-foreground">Pattern: </span>
                      {e.patternId}
                    </div>
                    <div>
                      <span className="text-muted-foreground">Marks: </span>
                      {e.totalMarks}
                    </div>
                    <div>
                      <span className="text-muted-foreground">Status: </span>
                      {e.status}
                    </div>
                  </CardContent>
                </Card>
              </Link>
            ))}
          </div>
        )}
        <div>
          <Button asChild variant="outline" size="sm">
            <Link href="/exams">View all exams</Link>
          </Button>
        </div>
      </section>
    </div>
  );
}
