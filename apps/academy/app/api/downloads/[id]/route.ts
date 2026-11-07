import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

// Who may fetch the file is decided by download_item_path() (staff of the campus, or a parent
// or student whose class it was shared with); the signed URL is only minted after it says yes.
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!z.string().uuid().safeParse(id).success) return NextResponse.json({ error: 'Invalid file.' }, { status: 400 });

  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('download_item_path', { p_id: id }).maybeSingle();
  if (!data) return NextResponse.json({ error: 'File not found.' }, { status: 404 });

  const { data: signed } = await supabaseServiceRole()
    .storage.from('downloads')
    .createSignedUrl(data.storage_path, 60, { download: data.original_filename });
  if (!signed) return NextResponse.json({ error: 'File is not available.' }, { status: 404 });
  return NextResponse.redirect(signed.signedUrl, { headers: { 'cache-control': 'private, no-store' } });
}
