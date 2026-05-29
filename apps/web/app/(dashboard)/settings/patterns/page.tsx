import Link from 'next/link';
import { and, desc, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { ALL_PATTERNS, type PatternSpec } from '@seena/shared/patterns';
import { FORMAT_LABELS, type Format } from '@seena/shared';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PatternFilter } from '@/components/pattern-builder/pattern-filter';

const FORMAT_VALUES: Format[] = [
  'paper',
  'quiz',
  'assignment',
  'homework',
  'midterm',
  'final',
  'mocktest',
];

function formatBadge(format: string) {
  return (
    <span className="inline-flex items-center rounded-full border bg-muted px-2 py-0.5 text-xs font-medium">
      {FORMAT_LABELS[format as Format] ?? format}
    </span>
  );
}

function patternMeta(p: { grade: number | null; subject: string | null; totalMarks: number }) {
  const parts: string[] = [];
  if (p.grade != null) parts.push(`Grade ${p.grade}`);
  if (p.subject) parts.push(p.subject);
  parts.push(`${p.totalMarks} marks`);
  return parts.join(' · ');
}

export default async function PatternsPage({
  searchParams,
}: {
  searchParams: Promise<{ format?: string }>;
}) {
  const { orgId } = await requireSession();
  const sp = await searchParams;
  const activeFormat = sp.format && FORMAT_VALUES.includes(sp.format as Format)
    ? (sp.format as Format)
    : null;

  const customRows = await db
    .select()
    .from(schema.customPatterns)
    .where(
      and(
        eq(schema.customPatterns.orgId, orgId),
        eq(schema.customPatterns.archived, false),
      ),
    )
    .orderBy(desc(schema.customPatterns.updatedAt));

  const builtIn: PatternSpec[] = activeFormat
    ? ALL_PATTERNS.filter((p) => p.format === activeFormat)
    : ALL_PATTERNS;

  const custom = activeFormat
    ? customRows.filter((p) => p.format === activeFormat)
    : customRows;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Exam Patterns</h1>
          <p className="text-sm text-muted-foreground">
            Reusable templates that drive how exams are structured.
          </p>
        </div>
        <Button asChild>
          <Link href="/settings/patterns/new">New pattern</Link>
        </Button>
      </div>

      <PatternFilter active={activeFormat} formats={FORMAT_VALUES} />

      <section className="space-y-3">
        <h2 className="text-sm font-medium text-muted-foreground">Built-in (read-only)</h2>
        {builtIn.length === 0 ? (
          <Card>
            <CardContent className="p-6 text-sm text-muted-foreground">
              No built-in patterns match this filter.
            </CardContent>
          </Card>
        ) : (
          <div className="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
            {builtIn.map((p) => (
              <Card key={p.id}>
                <CardHeader>
                  <CardTitle className="truncate text-base">{p.name}</CardTitle>
                </CardHeader>
                <CardContent className="text-sm">
                  <div className="mb-2 flex items-center gap-2">
                    <span className="text-xs text-muted-foreground">{p.board}</span>
                    {formatBadge(p.format)}
                  </div>
                  <div className="text-muted-foreground">{patternMeta(p)}</div>
                  <div className="mt-3">
                    <Link
                      href={`/settings/patterns/new?from=${encodeURIComponent(p.id)}`}
                      className="text-sm font-medium underline"
                    >
                      Use as starting point
                    </Link>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        )}
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-medium text-muted-foreground">Your patterns</h2>
        {custom.length === 0 ? (
          <Card>
            <CardContent className="p-6 text-sm text-muted-foreground">
              You haven't created any custom patterns yet.{' '}
              <Link href="/settings/patterns/new" className="underline">
                Create one
              </Link>
              .
            </CardContent>
          </Card>
        ) : (
          <div className="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
            {custom.map((p) => (
              <Card key={p.id}>
                <CardHeader>
                  <CardTitle className="truncate text-base">{p.name}</CardTitle>
                </CardHeader>
                <CardContent className="text-sm">
                  <div className="mb-2 flex items-center gap-2">
                    <span className="text-xs text-muted-foreground">{p.board}</span>
                    {formatBadge(p.format)}
                    {p.isDefault ? (
                      <span className="inline-flex items-center rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
                        Default
                      </span>
                    ) : null}
                  </div>
                  <div className="text-muted-foreground">{patternMeta(p)}</div>
                  <div className="mt-3">
                    <Link
                      href={`/settings/patterns/${p.id}`}
                      className="text-sm font-medium underline"
                    >
                      Edit
                    </Link>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
