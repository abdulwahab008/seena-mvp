import { desc, eq } from 'drizzle-orm';
import type { Question } from '@seena/shared';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { BankBrowser, type BankItem } from '@/components/bank/bank-browser';

export default async function BankPage() {
  const { orgId } = await requireSession();
  const rows = await db
    .select()
    .from(schema.bankQuestions)
    .where(eq(schema.bankQuestions.orgId, orgId))
    .orderBy(desc(schema.bankQuestions.createdAt))
    .limit(300);

  const items: BankItem[] = rows.map((r) => ({
    id: r.id,
    subject: r.subject,
    board: r.board,
    grade: r.grade,
    chapter: r.chapter,
    type: r.type,
    sourceExamId: r.sourceExamId,
    payload: r.payload as Question,
  }));

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Question Bank</h1>
      <p className="text-sm text-muted-foreground">
        Reusable questions you saved from generated exams.
      </p>
      <BankBrowser initial={items} />
    </div>
  );
}
