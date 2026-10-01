import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

// The student portal never receives the original (up to 5 MB): every visit
// re-checks the caller's RLS access to the title and redirects to a signed URL
// carrying an image transform (max 400 px wide, quality 60), which keeps a
// cover well under 200 KB.
const SIGNED_URL_SECONDS = 60 * 60;

export async function GET(_req: NextRequest, { params }: { params: Promise<{ titleId: string }> }) {
  const { titleId } = await params;
  if (!z.string().uuid().safeParse(titleId).success) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const supabase = await supabaseServer();
  const { data: row } = await supabase.from('library_title').select('cover_path').eq('id', titleId).maybeSingle();
  if (!row?.cover_path) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const { data, error } = await supabaseServiceRole()
    .storage.from('library-covers')
    .createSignedUrl(row.cover_path, SIGNED_URL_SECONDS, { transform: { width: 400, quality: 60, resize: 'contain' } });
  if (error || !data) return NextResponse.json({ error: 'unavailable' }, { status: 502 });
  return NextResponse.redirect(data.signedUrl, 302);
}
