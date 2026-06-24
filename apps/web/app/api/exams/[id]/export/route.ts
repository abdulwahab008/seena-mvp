import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { Exam } from '@seena/shared';
import { renderExamPdf } from '@/lib/pdf/render';
import { shuffleExam, VERSION_LABELS } from '@/lib/generation/shuffle-exam';
import { uploadBuffer, getSignedReadUrl } from '@/lib/storage';
import { rateLimit } from '@/lib/ratelimit';
import { apiError } from '@/lib/http';

const Body = z.object({
  format: z.enum(['pdf']).default('pdf'),
  versions: z.number().int().min(1).max(6).default(1),
});

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    await rateLimit(`export:${orgId}`, 30, 60);
    const { id } = await params;
    const { versions: versionCount } = Body.parse(await req.json().catch(() => ({})));

    const [exam] = await db
      .select()
      .from(schema.exams)
      .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
    if (!exam) return NextResponse.json({ error: 'not found' }, { status: 404 });

    const [org] = await db
      .select()
      .from(schema.organizations)
      .where(eq(schema.organizations.id, orgId));

    const examPayload = Exam.parse(exam.payload);

    // 1 version → original paper unchanged; N>1 → seeded-shuffled anti-leak variants.
    const versionList =
      versionCount <= 1
        ? [{ exam: examPayload }]
        : Array.from({ length: versionCount }, (_, i) => ({
            exam: shuffleExam(examPayload, (i + 1) * 0x9e3779b1),
            label: VERSION_LABELS[i],
          }));

    const pdfBuffer = await renderExamPdf({
      versions: versionList,
      orgName: org?.name ?? 'Seena Exams',
      orgLogoUrl: org?.logoUrl ?? null,
      language: exam.language as 'en' | 'ur' | 'mixed',
    });

    const key = `org_${orgId}/exports/${id}-${Date.now()}.pdf`;
    await uploadBuffer(key, pdfBuffer, 'application/pdf');
    const url = await getSignedReadUrl(key, 60 * 60 * 24);

    const [exportRow] = await db
      .insert(schema.examExports)
      .values({ examId: id, format: 'pdf', url })
      .returning();

    return NextResponse.json({ url, export: exportRow });
  } catch (e) {
    return apiError(e);
  }
}
