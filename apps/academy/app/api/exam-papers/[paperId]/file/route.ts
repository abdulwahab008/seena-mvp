import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { paperFileName } from '@/lib/exams/paper-html';

/**
 * FR-I07: downloads the rendered paper or its answer key. The path is derived
 * from the paper row by the database, so ?kind=key on a Set B paper can only
 * ever return key-B.pdf, and the filename carries the set code.
 */
export async function GET(request: NextRequest, { params }: { params: Promise<{ paperId: string }> }) {
  const { paperId } = await params;
  const kind = new URL(request.url).searchParams.get('kind') === 'key' ? 'key' : 'paper';
  const supabase = await supabaseServer();

  const { data: paths } = await supabase.rpc('fn_exam_paper_file_paths', { p_paper_id: paperId });
  const where = paths?.[0];
  if (!where) return NextResponse.json({ error: 'Paper not available.' }, { status: 403 });
  const { data: paper } = await supabase
    .from('exam_paper')
    .select('exam_subject:exam_subject_id(class_subject:class_subject_id(subject:subject_id(name_en)))')
    .eq('id', paperId)
    .maybeSingle();
  const es = Array.isArray(paper?.exam_subject) ? paper?.exam_subject[0] : paper?.exam_subject;
  const cs = es ? (Array.isArray(es.class_subject) ? es.class_subject[0] : es.class_subject) : null;
  const subject = cs ? (Array.isArray(cs.subject) ? cs.subject[0] : cs.subject) : null;

  const { data: blob } = await supabaseServiceRole().storage.from('exam-papers').download(kind === 'key' ? where.key_path : where.paper_path);
  if (!blob) return NextResponse.json({ error: 'That file has not been rendered yet.' }, { status: 404 });
  return new NextResponse(new Uint8Array(await blob.arrayBuffer()), {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `attachment; filename="${paperFileName(kind, subject?.name_en ?? 'paper', where.set_code)}"`,
      'cache-control': 'private, no-store',
      'x-paper-set': where.set_code,
    },
  });
}
