import Link from 'next/link';
import { desc, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export default async function BooksPage() {
  const { orgId } = await requireSession();
  const books = await db
    .select()
    .from(schema.books)
    .where(eq(schema.books.orgId, orgId))
    .orderBy(desc(schema.books.createdAt));

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Books</h1>
        <Button asChild>
          <Link href="/books/new">Upload book</Link>
        </Button>
      </div>

      {books.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            No books yet. Upload a textbook PDF to get started.
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
          {books.map((b) => (
            <Link key={b.id} href={`/books/${b.id}`} className="block">
              <Card className="h-full transition hover:bg-accent">
                <CardHeader>
                  <CardTitle className="truncate">{b.title}</CardTitle>
                </CardHeader>
                <CardContent className="text-sm">
                  <div className="grid gap-1">
                    <div>
                      <span className="text-muted-foreground">Subject: </span>
                      {b.subject}
                    </div>
                    <div>
                      <span className="text-muted-foreground">Grade: </span>
                      {b.grade ?? '—'}
                    </div>
                    <div>
                      <span className="text-muted-foreground">Board: </span>
                      {b.board}
                    </div>
                    <div>
                      <span className="text-muted-foreground">Status: </span>
                      <span
                        className={
                          b.status === 'ready'
                            ? 'text-green-600'
                            : b.status === 'failed'
                              ? 'text-red-600'
                              : 'text-amber-600'
                        }
                      >
                        {b.status}
                        {b.status === 'ready' ? ` · ${b.chunkCount} chunks` : ''}
                      </span>
                    </div>
                    {b.failureReason ? (
                      <div className="text-xs text-red-600">{b.failureReason}</div>
                    ) : null}
                  </div>
                </CardContent>
              </Card>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
