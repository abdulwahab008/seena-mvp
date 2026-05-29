import { notFound } from 'next/navigation';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { PatternSpec } from '@seena/shared/patterns';
import { PatternBuilder } from '@/components/pattern-builder/pattern-builder';

export default async function EditPatternPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { orgId } = await requireSession();
  const { id } = await params;
  const [row] = await db
    .select()
    .from(schema.customPatterns)
    .where(
      and(
        eq(schema.customPatterns.id, id),
        eq(schema.customPatterns.orgId, orgId),
        eq(schema.customPatterns.archived, false),
      ),
    );
  if (!row) notFound();
  const initial = PatternSpec.parse({
    id: row.id,
    name: row.name,
    board: row.board,
    format: row.format,
    grade: row.grade,
    subject: row.subject,
    totalMarks: row.totalMarks,
    sections: row.sections,
    notes: row.notes ?? undefined,
  });
  return (
    <div className="mx-auto max-w-3xl">
      <PatternBuilder mode="edit" patternId={row.id} initial={initial} />
    </div>
  );
}
