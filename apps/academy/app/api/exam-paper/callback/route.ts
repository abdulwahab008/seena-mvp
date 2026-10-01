import { NextResponse, type NextRequest } from 'next/server';
import { z } from 'zod';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { verifyCallbackSignature } from '@/lib/exams/paper-worker';

/**
 * FR-I05 (the exam-paper-callback function). The worker POSTs the generated
 * paper here, signed with an HMAC-SHA256 of the raw body in x-seena-signature
 * (secret: EXAM_PAPER_CALLBACK_SECRET; unset means every callback is refused).
 * The service-role call is idempotent on the job id inside
 * fn_ingest_generated_paper(), so a retried webhook answers 200 with the paper
 * already stored instead of making a second one.
 */
const Body = z.object({ job_id: z.string().uuid(), payload: z.unknown() });

export async function POST(request: NextRequest) {
  const raw = await request.text();
  if (!verifyCallbackSignature(raw, request.headers.get('x-seena-signature'))) {
    return NextResponse.json({ error: 'Unauthorized: invalid or missing signature.' }, { status: 401 });
  }
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return NextResponse.json({ error: 'Malformed JSON.' }, { status: 400 });
  }
  const parsed = Body.safeParse(json);
  if (!parsed.success) return NextResponse.json({ error: 'job_id and payload are required.' }, { status: 400 });

  const { data, error } = await supabaseServiceRole().rpc('fn_ingest_generated_paper', {
    p_job_id: parsed.data.job_id,
    p_payload: parsed.data.payload as never,
  });
  if (error) return NextResponse.json({ error: error.message.includes('JOB_NOT_FOUND') ? 'Unknown job.' : 'Could not store the paper.' }, { status: error.message.includes('JOB_NOT_FOUND') ? 404 : 500 });
  return NextResponse.json(data);
}
