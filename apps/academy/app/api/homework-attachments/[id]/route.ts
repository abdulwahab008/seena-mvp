import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

const SIGNED_URL_SECONDS = 60 * 60;

// A stable link that never expires: every visit re-checks the caller's RLS
// access to the attachment row and redirects to a fresh 60-minute signed URL,
// so an old tab or a bookmarked link transparently gets a new one.
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!z.string().uuid().safeParse(id).success) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const supabase = await supabaseServer();
  const { data: row } = await supabase.from('homework_attachment').select('storage_path, original_filename').eq('id', id).maybeSingle();
  if (!row) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const { data, error } = await supabaseServiceRole().storage.from('homework-attachments').createSignedUrl(row.storage_path, SIGNED_URL_SECONDS, { download: row.original_filename });
  if (error || !data) return NextResponse.json({ error: 'unavailable' }, { status: 502 });
  return NextResponse.redirect(data.signedUrl, 302);
}
