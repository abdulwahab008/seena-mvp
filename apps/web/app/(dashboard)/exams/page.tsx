import Link from 'next/link';
import { desc, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export default async function ExamsPage() {
  const { orgId } = await requireSession();
  const exams = await db
    .select()
    .from(schema.exams)
    .where(eq(schema.exams.orgId, orgId))
    .orderBy(desc(schema.exams.createdAt))
    .limit(100);

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Exams</h1>
      {exams.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            No exams yet. Generate one from the Chat page.
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-3 md:grid-cols-2">
          {exams.map((e) => (
            <Link key={e.id} href={`/exams/${e.id}`} className="block">
              <Card className="transition hover:bg-accent">
                <CardHeader>
                  <CardTitle className="truncate">{e.title}</CardTitle>
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
    </div>
  );
}
