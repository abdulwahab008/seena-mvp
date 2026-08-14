import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';
import { verifyPdfDigest } from '@/lib/certificates/seal';

/**
 * FR-J12: the merged, print-ready collation.
 *
 * Same handler shape as FR-J09's single-card download and for the same reason:
 * the object is fetched AS THE SIGNED-IN USER, so report_card_batch's RLS and
 * the bucket's own read policy are what decide who may read it, and the bytes
 * are re-hashed against the digest sealed when the batch completed.
 *
 * The one difference is what a mismatch means. An individual card's mismatch
 * is refused because that document is the one a parent was handed and it can
 * only be corrected by issuing the next revision. A merged file is a
 * collation, rebuilt in full whenever the batch is re-run — so a mismatch here
 * is stale bytes from a run that has since moved on, which is still a refusal
 * (409, nothing served) but names re-running the batch as the remedy rather
 * than raising a question about the documents themselves.
 *
 * A batch with no checksum has not sealed a merged file: either it is still
 * running, or every candidate in it was skipped. Both are 404 with the counts,
 * because there is nothing to send and the counts say why.
 */

export async function GET(_request: NextRequest, { params }: { params: Promise<{ batchId: string }> }) {
  const { batchId } = await params;
  const supabase = await supabaseServer();

  const { data: batch } = await supabase
    .from('report_card_batch')
    .select('id, status, file_path, checksum, total, succeeded, skipped, failed')
    .eq('id', batchId)
    .maybeSingle();
  if (!batch) return NextResponse.json({ error: 'Batch not found.' }, { status: 404 });

  if (!batch.checksum || !batch.file_path) {
    return NextResponse.json(
      {
        error:
          batch.succeeded === 0 && batch.status === 'completed'
            ? 'No card in this batch could be produced, so there is no merged file.'
            : 'The merged file for this batch is not ready yet.',
        status: batch.status,
        total: batch.total,
        succeeded: batch.succeeded,
        skipped: batch.skipped,
        failed: batch.failed,
      },
      { status: 404 },
    );
  }

  const { data: blob } = await supabase.storage.from('report-cards').download(batch.file_path);
  if (!blob) {
    return NextResponse.json({ error: 'The merged file for this batch is not in storage.' }, { status: 404 });
  }

  const bytes = new Uint8Array(await blob.arrayBuffer());
  const verdict = verifyPdfDigest(bytes, batch.checksum);

  if (verdict.status === 'mismatch') {
    return NextResponse.json(
      {
        error: 'This merged file has changed since the batch sealed it. Re-run the batch to rebuild it.',
        expectedSha256: verdict.expected,
        observedSha256: verdict.observed,
      },
      { status: 409, headers: { 'x-pdf-digest-status': 'mismatch', 'cache-control': 'no-store' } },
    );
  }

  return new NextResponse(bytes, {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="report-cards-batch.pdf"`,
      'cache-control': 'no-store',
      'x-pdf-digest-status': verdict.status,
      'x-pdf-sha256': verdict.observed,
      'x-report-card-batch-succeeded': String(batch.succeeded),
      'x-report-card-batch-skipped': String(batch.skipped + batch.failed),
    },
  });
}
