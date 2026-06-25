import { NextResponse } from 'next/server';
import { z } from 'zod';
import { requireSession } from '@/lib/auth';
import { createSignedUploadUrl } from '@/lib/storage';
import { rateLimit } from '@/lib/ratelimit';
import { apiError } from '@/lib/http';

const Body = z.object({
  filename: z.string().min(1).max(200).regex(/\.pdf$/i, 'filename must end in .pdf'),
  contentType: z.literal('application/pdf').default('application/pdf'),
});

export async function POST(req: Request) {
  try {
    const { orgId } = await requireSession();
    await rateLimit(`book-upload:${orgId}`, 30, 60);
    const body = Body.parse(await req.json());
    const { key, signedUrl, token } = await createSignedUploadUrl(orgId, body.filename);
    return NextResponse.json({ key, signedUrl, token });
  } catch (e) {
    return apiError(e);
  }
}
