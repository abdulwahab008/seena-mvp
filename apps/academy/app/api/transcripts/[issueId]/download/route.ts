import { NextResponse, type NextRequest } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { verifyPdfDigest } from '@/lib/certificates/seal';

/**
 * FR-J13: the only way an issued transcript leaves this system.
 *
 * The FR asks for 30-day signed URLs; this replaces them for FR-T09's reason.
 * A signed URL sends bytes from storage to the browser and checks nothing, so
 * the digest sealed on the register would never be compared. Here the object
 * is fetched AS THE SIGNED-IN USER — transcript_issue's RLS (tenant staff, the
 * student, the parent once issued) and the bucket's read policy decide who may
 * read it — re-hashed, and compared. A mismatch is 409 and no bytes.
 */
export async function GET(_request: NextRequest, { params }: { params: Promise<{ issueId: string }> }) {
  const { issueId } = await params;
  if (!z.string().uuid().safeParse(issueId).success) return NextResponse.json({ error: 'Invalid transcript.' }, { status: 400 });
  const supabase = await supabaseServer();

  const { data: issue } = await supabase
    .from('transcript_issue')
    .select('id, serial_no, status, storage_path, pdf_sha256')
    .eq('id', issueId)
    .maybeSingle();
  if (!issue || issue.status !== 'issued') return NextResponse.json({ error: 'Transcript not found.' }, { status: 404 });

  const { data: blob } = await supabase.storage.from('transcripts').download(issue.storage_path);
  if (!blob) return NextResponse.json({ error: 'The transcript is not in storage.', serialNo: issue.serial_no }, { status: 404 });

  const bytes = new Uint8Array(await blob.arrayBuffer());
  const verdict = verifyPdfDigest(bytes, issue.pdf_sha256);
  if (verdict.status === 'mismatch') {
    return NextResponse.json(
      { error: 'This transcript has been altered since it was issued and cannot be downloaded.', serialNo: issue.serial_no, expectedSha256: verdict.expected, observedSha256: verdict.observed },
      { status: 409, headers: { 'x-pdf-digest-status': 'mismatch', 'cache-control': 'no-store' } },
    );
  }
  return new NextResponse(bytes, {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="transcript-${issue.serial_no}.pdf"`,
      'cache-control': 'no-store',
      'x-pdf-digest-status': verdict.status,
      'x-pdf-sha256': verdict.observed,
    },
  });
}
