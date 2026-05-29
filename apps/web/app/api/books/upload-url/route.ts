import { NextResponse } from 'next/server';
import { z } from 'zod';
import { requireSession } from '@/lib/auth';
import { createSignedUploadUrl } from '@/lib/storage';

const Body = z.object({
  filename: z.string().min(1),
  contentType: z.string().default('application/pdf'),
});

export async function POST(req: Request) {
  try {
    const { orgId } = await requireSession();
    const body = Body.parse(await req.json());
    const { key, signedUrl, token } = await createSignedUploadUrl(orgId, body.filename);
    return NextResponse.json({ key, signedUrl, token });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
