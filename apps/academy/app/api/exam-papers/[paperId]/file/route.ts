import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { paperFileName } from '@/lib/exams/paper-html';
import { clientIpFromHeaders } from '@/lib/request-ip';

/**
 * FR-I08 (the issue-paper-download-url function): the only way out of the
 * private exam-papers bucket.
 *
 * Every request, granted or refused, is one row in exam_paper_access, written by
 * fn_request_paper_access() with the caller's user, role and IP. A refusal is a
 * 403 that says when the paper releases (a published paper is sealed until its
 * slot start minus the campus release offset). A grant is a 15-minute signed URL
 * for the file at the path the DATABASE derived from the paper's row and set
 * code, so ?kind=key on a Set B paper can only ever sign key-B.pdf.
 *
 * ?format=json returns the URL and the filename; otherwise the browser is
 * redirected to the signed URL, which downloads as the set-coded filename.
 */
const FIFTEEN_MINUTES = 15 * 60;

export async function GET(request: NextRequest, { params }: { params: Promise<{ paperId: string }> }) {
  const { paperId } = await params;
  const url = new URL(request.url);
  const kind = url.searchParams.get('kind') === 'key' ? 'key' : 'paper';
  const supabase = await supabaseServer();

  const { data, error } = await supabase.rpc('fn_request_paper_access', { p_paper_id: paperId, p_kind: kind, p_ip: clientIpFromHeaders(request.headers) ?? undefined });
  if (error) {
    const status = error.message.includes('PAPER_NOT_FOUND') ? 404 : 400;
    return NextResponse.json({ error: status === 404 ? 'Paper not found.' : 'Invalid request.' }, { status });
  }
  const result = data as unknown as { granted: boolean; reason: string; path: string | null; release_at: string | null; set_code: string };
  if (!result.granted) {
    const message =
      result.reason === 'sealed'
        ? `This paper is sealed until ${result.release_at ? new Date(result.release_at).toISOString() : 'its release time'}.`
        : result.reason === 'no_exam_slot'
          ? 'This paper has no scheduled exam, so it is not released.'
          : 'You are not allowed to obtain this paper.';
    return NextResponse.json({ error: message, reason: result.reason, release_at: result.release_at }, { status: 403, headers: { 'cache-control': 'no-store' } });
  }

  const { data: paper } = await supabase
    .from('exam_paper')
    .select('exam_subject:exam_subject_id(class_subject:class_subject_id(subject:subject_id(name_en)))')
    .eq('id', paperId)
    .maybeSingle();
  const es = Array.isArray(paper?.exam_subject) ? paper?.exam_subject[0] : paper?.exam_subject;
  const cs = es ? (Array.isArray(es.class_subject) ? es.class_subject[0] : es.class_subject) : null;
  const subject = cs ? (Array.isArray(cs.subject) ? cs.subject[0] : cs.subject) : null;
  const filename = paperFileName(kind, subject?.name_en ?? 'paper', result.set_code);

  const { data: signed, error: signError } = await supabaseServiceRole().storage.from('exam-papers').createSignedUrl(result.path!, FIFTEEN_MINUTES, { download: filename });
  if (signError || !signed) return NextResponse.json({ error: 'That file has not been rendered yet.' }, { status: 404 });
  if (url.searchParams.get('format') === 'json') {
    return NextResponse.json({ url: signed.signedUrl, expires_in: FIFTEEN_MINUTES, filename, set_code: result.set_code }, { headers: { 'cache-control': 'no-store' } });
  }
  return NextResponse.redirect(signed.signedUrl, { status: 302, headers: { 'cache-control': 'no-store' } });
}
