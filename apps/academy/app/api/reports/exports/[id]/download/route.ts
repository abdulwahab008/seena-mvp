import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

// Only the requester downloads their file. A purged or expired export answers
// 410 Gone, so a link that outlives the 30-day retention never serves anything.
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!z.string().uuid().safeParse(id).success) return NextResponse.json({ error: 'Invalid export.' }, { status: 400 });

  const supabase = await supabaseServer();
  const { data: user } = await supabase.auth.getUser();
  const { data: job } = await supabase.from('v_report_export_job').select('id, requested_by, status, downloadable, expires_at, dataset_key').eq('id', id).maybeSingle();
  if (!job || !user.user || job.requested_by !== user.user.id) return NextResponse.json({ error: 'Export not found.' }, { status: 404 });
  if (job.status === 'expired' || (job.status === 'done' && !job.downloadable)) return NextResponse.json({ error: 'This export has expired and was deleted.' }, { status: 410 });
  if (job.status !== 'done') return NextResponse.json({ error: 'This export is not ready yet.' }, { status: 409 });

  const admin = supabaseServiceRole();
  const { data: row } = await admin.from('report_export_job').select('storage_path').eq('id', id).single();
  if (!row?.storage_path) return NextResponse.json({ error: 'This export has expired and was deleted.' }, { status: 410 });
  const { data: file, error } = await admin.storage.from('report_exports').download(row.storage_path);
  if (error || !file) return NextResponse.json({ error: 'The file is unavailable.' }, { status: 410 });

  return new NextResponse(file.stream(), {
    headers: {
      'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'content-disposition': `attachment; filename="${job.dataset_key}-${id.slice(0, 8)}.xlsx"`,
      'cache-control': 'private, no-store',
    },
  });
}
