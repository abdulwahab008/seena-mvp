import { notFound } from 'next/navigation';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { Exam } from '@seena/shared';
import { ExamView } from '@/components/exam-builder/exam-view';

export default async function ExamDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { orgId } = await requireSession();
  const { id } = await params;
  const [exam] = await db
    .select()
    .from(schema.exams)
    .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
  if (!exam) notFound();
  const payload = Exam.parse(exam.payload);
  return <ExamView examId={exam.id} initialPayload={payload} title={exam.title} />;
}
