import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { Exam } from '@seena/shared';
import { renderExamPdf } from '@/lib/pdf/render';
import { uploadBuffer, getSignedReadUrl } from '@/lib/storage';

const Body = z.object({ format: z.enum(['pdf']).default('pdf') });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    const { id } = await params;
    Body.parse(await req.json().catch(() => ({})));

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

    const pdfBuffer = await renderExamPdf({
      exam: examPayload,
      orgName: org?.name ?? 'Seena Exams',
      orgLogoUrl: org?.logoUrl ?? null,
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
    console.error('[export-pdf] failed', e);
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
