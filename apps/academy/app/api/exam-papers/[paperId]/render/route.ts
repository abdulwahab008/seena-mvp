import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { buildAnswerKeyHtml, buildQuestionPaperHtml, collectPaperStrings } from '@/lib/exams/paper-html';
import { loadPaperPrintPayload } from '@/lib/exams/paper-print-query';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, renderPdf, stampPdfTimestamps } from '@/lib/pdf/render';

/**
 * FR-I07: renders a paper and ITS OWN answer key into the private exam-papers
 * bucket. The two storage paths come from the database
 * (fn_exam_paper_file_paths), which derives them from the paper row and its set
 * code: the caller cannot choose where a file goes, so a Set B paper cannot be
 * filed beside the Set A key.
 *
 * Who may render: whoever can see the paper (its requester or the exam office of
 * the campus), checked first through fn_exam_paper_file_paths(). The content is
 * then read as the system, because a PUBLISHED paper's questions are sealed from
 * clients until its exam window opens (FR-I08) and the sealed file still has to
 * be produced. Rendering hands the file to nobody: FR-I08's download gate does,
 * and records every request.
 */
export async function POST(_request: NextRequest, { params }: { params: Promise<{ paperId: string }> }) {
  const { paperId } = await params;
  const supabase = await supabaseServer();

  const { data: paths, error: pathError } = await supabase.rpc('fn_exam_paper_file_paths', { p_paper_id: paperId });
  const where = paths?.[0];
  if (pathError || !where) return NextResponse.json({ error: 'Paper not available.' }, { status: 403 });
  const payload = await loadPaperPrintPayload(supabaseServiceRole(), paperId);
  if (!payload) return NextResponse.json({ error: 'Paper not found.' }, { status: 404 });

  const font = resolveNastaliqFont();
  const missing = font ? checkGlyphCoverage(collectPaperStrings(payload), parseCmapRanges(font.bytes)).missing : [];
  const stamp = new Date(Date.UTC(2026, 0, 1));
  let paperPdf: Uint8Array;
  let keyPdf: Uint8Array;
  try {
    paperPdf = stampPdfTimestamps(new Uint8Array(await renderPdf(buildQuestionPaperHtml(payload, font))), stamp);
    keyPdf = stampPdfTimestamps(new Uint8Array(await renderPdf(buildAnswerKeyHtml(payload, font))), stamp);
  } catch (cause) {
    const message = cause instanceof RendererUnavailableError ? 'No PDF renderer is available on this server.' : 'Could not render the paper.';
    return NextResponse.json({ error: message }, { status: 503 });
  }

  const admin = supabaseServiceRole();
  const up1 = await admin.storage.from('exam-papers').upload(where.paper_path, paperPdf, { contentType: 'application/pdf', upsert: true });
  const up2 = await admin.storage.from('exam-papers').upload(where.key_path, keyPdf, { contentType: 'application/pdf', upsert: true });
  if (up1.error || up2.error) return NextResponse.json({ error: 'Could not store the rendered files.' }, { status: 502 });
  return NextResponse.json({ set_code: where.set_code, paper_path: where.paper_path, key_path: where.key_path, missing_glyphs: missing });
}
