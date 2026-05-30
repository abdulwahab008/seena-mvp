import Link from 'next/link';
import { count, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { getExamQuota } from '@/lib/quota';
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
  const quota = await getExamQuota(orgId);
  const quotaPct = Math.min(100, Math.round((quota.used / Math.max(quota.limit, 1)) * 100));

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
        <Card>
          <CardHeader>
            <CardTitle>This month</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-3xl font-semibold">
              {quota.used}
              <span className="text-base font-normal text-muted-foreground"> / {quota.limit}</span>
            </div>
            <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-muted">
              <div
                className={quotaPct >= 100 ? 'h-full bg-red-500' : quotaPct >= 80 ? 'h-full bg-amber-500' : 'h-full bg-green-500'}
                style={{ width: `${quotaPct}%` }}
              />
            </div>
            <div className="mt-1 text-xs text-muted-foreground">
              exams generated · resets on the 1st
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
