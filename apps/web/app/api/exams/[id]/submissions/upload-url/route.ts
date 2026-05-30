import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { createSignedUploadUrl } from '@/lib/storage';
import { rateLimit } from '@/lib/ratelimit';
import { apiError } from '@/lib/http';

const Body = z.object({
  filename: z
    .string()
    .min(1)
    .max(200)
    .regex(/\.(pdf|png|jpe?g|webp)$/i, 'file must be a PDF or image (png/jpg/webp)'),
  contentType: z
    .enum(['application/pdf', 'image/png', 'image/jpeg', 'image/webp'])
    .default('application/pdf'),
});

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    await rateLimit(`sheet-upload:${orgId}`, 30, 60);
    const { id } = await params;

    const [exam] = await db
      .select({ id: schema.exams.id })
      .from(schema.exams)
      .where(and(eq(schema.exams.id, id), eq(schema.exams.orgId, orgId)));
    if (!exam) return NextResponse.json({ error: 'not found' }, { status: 404 });

    const body = Body.parse(await req.json());
    const { key, signedUrl } = await createSignedUploadUrl(orgId, body.filename);
    return NextResponse.json({ key, signedUrl });
  } catch (e) {
    return apiError(e);
  }
}
