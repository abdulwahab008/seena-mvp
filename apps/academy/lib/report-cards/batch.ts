import type { supabaseServer } from '@/lib/supabase/server';
import { resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, pdfPageCount, renderPdf, stampPdfTimestamps } from '@/lib/pdf/render';
import { sha256Hex } from '@/lib/certificates/seal';
import { buildMergedReportCardHtml, type ReportCardSnapshot } from './html';
import { renderAndStoreReportCard, reportCardAssets, type ReservedReportCard } from './render';
import type { ReportCardBatch } from '@/lib/exams/report-card-batch-query';

/**
 * FR-J12: the driver.
 *
 * The database owns the batch — who is in it, in what order, what happened to
 * each of them and whether the merged document is sealed. This module owns
 * only the two things Postgres cannot do: produce PDF bytes and put them in a
 * bucket. It renders nothing that FR-J09 does not already render, and decides
 * nothing that the migration does not already decide.
 *
 * The loop is deliberately shaped as "claim one, render one, report one":
 *
 *   claim_report_card_batch_item()   commits either a skip or a reserved
 *                                    revision, so nothing is in flight across
 *                                    a request boundary except one card;
 *   renderAndStoreReportCard()       FR-J09's own path, unchanged, including
 *                                    its void-on-failure rule;
 *   finish_report_card_batch_item()  commits what the bytes did.
 *
 * A driver that dies anywhere in there loses at most that one card: the
 * migration reclaims an item left 'rendering' after fifteen minutes and voids
 * the revision it had reserved. Calling advanceReportCardBatch() again picks
 * up from the next pending row — which is why this is a real resumable batch
 * and not a long request pretending to be one.
 *
 * SLICE is what a single server action will attempt before returning progress
 * to the screen. It is not a throughput knob: the browser calls this again
 * immediately, and the only thing it decides is how often the progress row
 * moves. Twelve is roughly a section per round trip.
 *
 * The honest limit: each individual card is rendered through renderPdf(),
 * which launches its own headless Chromium. That is FR-F15's seam and FR-J09's
 * single-card cost, unchanged — sharing one browser across the slice would be
 * a change to a renderer three other FRs depend on, and it is not this FR's
 * change to make. AC1's five minutes is therefore a property of the machine
 * the driver runs on and nothing here asserts it.
 */

type ServerClient = Awaited<ReturnType<typeof supabaseServer>>;

const SLICE = 12;

type ClaimResult =
  | { done: boolean; batch: ReportCardBatch }
  | { item_id: string; status: 'skipped'; error_code: string }
  | { item_id: string; status: 'rendering'; reserved: ReservedReportCard };

type ManifestCard = { enrolment_id: string; seq: number; page_count: number; snapshot: ReportCardSnapshot };
type Manifest = { batch_id: string; file_path: string | null; cards: ManifestCard[] };

/**
 * AC3's merged, print-ready document.
 *
 * Built from the FROZEN snapshots of the cards that succeeded, never from
 * today's rows and never by re-rendering them — which is what makes AC4's
 * "the merged PDF is rebuilt in full" cost only the collation and leaves the
 * 114 documents already in parents' hands untouched.
 *
 * The timestamp stamped into the file is the latest rendered_at among the
 * cards it contains rather than the clock, so rebuilding the same collation
 * twice produces the same bytes and the checksum on the batch is a statement
 * about the document rather than about the minute it was collated.
 */
async function buildAndStoreMergedPdf(
  supabase: ServerClient,
  batch: ReportCardBatch,
): Promise<{ error: string | null }> {
  const { data, error } = await supabase.rpc('fn_report_card_batch_manifest', { p_batch_id: batch.batch_id });
  if (error || !data) return { error: 'Could not read the batch manifest.' };
  const manifest = data as unknown as Manifest;

  if (manifest.cards.length === 0 || !manifest.file_path) {
    // Nothing succeeded. The batch still completes — every candidate has an
    // outcome and a reason — but there is no collation to seal, and the
    // reserved path is released rather than left pointing at nothing.
    const { error: completeError } = await supabase.rpc('complete_report_card_batch', { p_batch_id: batch.batch_id });
    return { error: completeError ? 'Could not close the batch.' : null };
  }

  const font = resolveNastaliqFont();
  const cards = manifest.cards.map((c) => ({ snapshot: c.snapshot, pageCount: c.page_count }));
  const first = cards[0]!.snapshot;
  const assets = await reportCardAssets(supabase, first);
  const title = `${first.student.class_name} — ${first.term.name} ${first.term.session_name}`;

  let pdf: Buffer;
  try {
    pdf = await renderPdf(buildMergedReportCardHtml(cards, font, assets, title));
  } catch (cause) {
    const reason =
      cause instanceof RendererUnavailableError
        ? 'No PDF renderer is available on this server, so the merged file was not produced.'
        : 'The merged report card file could not be rendered.';
    await supabase.rpc('fail_report_card_batch', { p_batch_id: batch.batch_id, p_error: reason });
    return { error: reason };
  }

  const latest = cards.reduce(
    (acc, c) => (new Date(c.snapshot.rendered_at) > acc ? new Date(c.snapshot.rendered_at) : acc),
    new Date(cards[0]!.snapshot.rendered_at),
  );
  const bytes = stampPdfTimestamps(new Uint8Array(pdf), latest);

  // upsert: true, and it is the only object in this bucket that is. AC4
  // rebuilds this file in full; the individual cards behind it are each
  // separately sealed and can never be overwritten.
  const { error: uploadError } = await supabase.storage
    .from('report-cards')
    .upload(manifest.file_path, bytes, { contentType: 'application/pdf', upsert: true });
  if (uploadError) {
    const reason = 'The merged report card file could not be stored.';
    await supabase.rpc('fail_report_card_batch', { p_batch_id: batch.batch_id, p_error: reason });
    return { error: reason };
  }

  const { data: storedBlob } = await supabase.storage.from('report-cards').download(manifest.file_path);
  if (!storedBlob) {
    const reason = 'The stored merged file could not be read back.';
    await supabase.rpc('fail_report_card_batch', { p_batch_id: batch.batch_id, p_error: reason });
    return { error: reason };
  }
  const storedBytes = new Uint8Array(await storedBlob.arrayBuffer());

  const { error: completeError } = await supabase.rpc('complete_report_card_batch', {
    p_batch_id: batch.batch_id,
    p_sha256: sha256Hex(storedBytes),
    p_page_count: pdfPageCount(storedBytes),
  });
  if (completeError) {
    await supabase.rpc('fail_report_card_batch', {
      p_batch_id: batch.batch_id,
      p_error: `The merged file could not be sealed: ${completeError.message}`,
    });
    return { error: 'The merged report card file could not be sealed.' };
  }

  return { error: null };
}

/**
 * One slice of work. Returns the batch as the screen should show it, whether
 * or not there is more to do — `pending` is what tells the caller to come
 * back, and it is counted by the database rather than inferred here.
 */
export async function advanceReportCardBatch(
  supabase: ServerClient,
  batchId: string,
): Promise<{ error: string | null; batch?: ReportCardBatch }> {
  for (let i = 0; i < SLICE; i += 1) {
    const { data, error } = await supabase.rpc('claim_report_card_batch_item', { p_batch_id: batchId });
    if (error || !data) return { error: 'Could not take the next candidate in the batch.' };
    const claim = data as unknown as ClaimResult;

    if ('done' in claim) {
      if (!claim.done) return { error: null, batch: claim.batch };
      if (claim.batch.status === 'completed' && claim.batch.checksum !== null) {
        return { error: null, batch: claim.batch };
      }
      const merged = await buildAndStoreMergedPdf(supabase, claim.batch);
      const { data: after } = await supabase.rpc('fn_report_card_batch_status', { p_batch_id: batchId });
      return { error: merged.error, batch: (after ?? claim.batch) as unknown as ReportCardBatch };
    }

    if (claim.status === 'skipped') continue;

    const stored = await renderAndStoreReportCard(supabase, claim.reserved);
    const { error: finishError } = await supabase.rpc('finish_report_card_batch_item', {
      p_item_id: claim.item_id,
      p_ok: stored.error === null,
      p_error_code: stored.error === null ? undefined : 'render_failed',
      p_page_count: stored.pageCount ?? undefined,
    });
    if (finishError) return { error: 'Could not record the outcome of a card in the batch.' };
  }

  const { data, error } = await supabase.rpc('fn_report_card_batch_status', { p_batch_id: batchId });
  if (error || !data) return { error: 'Could not read the batch.' };
  return { error: null, batch: data as unknown as ReportCardBatch };
}
