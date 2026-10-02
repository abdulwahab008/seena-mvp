import { NextResponse, type NextRequest } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { createPaperJob } from '@/lib/exams/paper-request';

/**
 * FR-I05 (the exam-paper-request function): verifies the caller's session, writes
 * the queued job row and hands it to the worker. Answers 202 with the job id
 * straight after the row exists; the paper arrives later through the callback.
 */
const Body = z.object({
  examSubjectId: z.string().uuid(),
  boardPatternId: z.string().uuid(),
  chapters: z.array(z.string().trim().min(1).max(80)).min(1).max(40),
  totalMarks: z.number().int().min(1).max(1000),
  setCount: z.number().int().min(1).max(4).default(1),
});

export async function POST(request: NextRequest) {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'Sign in required.' }, { status: 401 });

  const parsed = Body.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: parsed.error.issues[0]?.message ?? 'Invalid request.' }, { status: 400 });

  const { jobId, error } = await createPaperJob(supabase, parsed.data);
  if (error) return NextResponse.json({ error }, { status: error.includes('permission') ? 403 : 400 });
  return NextResponse.json({ job_id: jobId, status: 'queued' }, { status: 202 });
}
