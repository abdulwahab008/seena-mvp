'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { renderAndStoreTranscript, type IssuedTranscript } from '@/lib/transcripts/render';
import { transcriptError } from '@/lib/transcripts/errors';
import { issueTranscriptSchema } from '@/lib/validation';

/**
 * FR-J13. Issuing is two steps for the reason FR-J09's is: the database
 * allocates the serial and freezes the document in one transaction
 * (issue_transcript), and the PDF is rendered from that snapshot afterwards.
 */
export type IssueTranscriptState = { error: string | null; serialNo?: string; downloadUrl?: string };

export async function issueTranscript(input: unknown): Promise<IssueTranscriptState> {
  const parsed = issueTranscriptSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('issue_transcript', {
    p_student_id: parsed.data.studentId,
    p_purpose: parsed.data.purpose,
  });
  if (error || !data) return { error: transcriptError(error?.message ?? '') };
  const stored = await renderAndStoreTranscript(supabase, data as unknown as IssuedTranscript);
  revalidatePath('/transcripts');
  if (stored.error) return { error: stored.error };
  return { error: null, serialNo: stored.serialNo, downloadUrl: stored.downloadUrl };
}
