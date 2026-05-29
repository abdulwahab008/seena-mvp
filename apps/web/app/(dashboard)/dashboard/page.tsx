import Link from 'next/link';
import { count, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';

export default async function DashboardPage() {
  const { orgId } = await requireSession();

  const [bookCount] = await db
    .select({ n: count() })
    .from(schema.books)
    .where(eq(schema.books.orgId, orgId));
  const [examCount] = await db
    .select({ n: count() })
    .from(schema.exams)
    .where(eq(schema.exams.orgId, orgId));

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Dashboard</h1>
        <div className="flex gap-2">
          <Button asChild variant="outline">
            <Link href="/books/new">Upload book</Link>
          </Button>
          <Button asChild>
            <Link href="/chat">New exam</Link>
          </Button>
        </div>
      </div>
      <div className="grid grid-cols-2 gap-4 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle>Books</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-3xl font-semibold">{bookCount?.n ?? 0}</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Exams</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-3xl font-semibold">{examCount?.n ?? 0}</div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
