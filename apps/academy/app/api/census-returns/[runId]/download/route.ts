import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

// FR-T13: the stored return. Visibility is the run's own RLS (census_run_campus_scope): a Principal
// downloads only their campus's returns, an owner any campus of the school.
export async function GET(_req: NextRequest, { params }: { params: Promise<{ runId: string }> }) {
  const { runId } = await params;
  if (!z.string().uuid().safeParse(runId).success) return NextResponse.json({ error: 'Invalid return.' }, { status: 400 });
  const supabase = await supabaseServer();
  const { data: run } = await supabase.from('census_return_run').select('id, framework, census_date, file_path, status').eq('id', runId).maybeSingle();
  if (!run || !run.file_path || run.status !== 'done') return NextResponse.json({ error: 'Return not found.' }, { status: 404 });

  const { data: file, error } = await supabaseServiceRole().storage.from('census-returns').download(run.file_path);
  if (error || !file) return NextResponse.json({ error: 'The file is unavailable.' }, { status: 404 });
  const ext = run.file_path.split('.').pop() ?? 'bin';
  return new NextResponse(file.stream(), {
    headers: {
      'content-type': ext === 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'text/csv; charset=utf-8',
      'content-disposition': `attachment; filename="${run.framework}-${run.census_date}.${ext}"`,
      'cache-control': 'private, no-store',
    },
  });
}
