import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

// RLS decides who may read the file row (the student, their guardian, or the
// homework's teacher once the submission is final); the signed URL lasts 60 minutes.
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!z.string().uuid().safeParse(id).success) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const supabase = await supabaseServer();
  const { data: row } = await supabase.from('homework_submission_file').select('storage_path, original_filename').eq('id', id).maybeSingle();
  if (!row) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const { data, error } = await supabaseServiceRole().storage.from('homework-submissions').createSignedUrl(row.storage_path, 60 * 60, { download: row.original_filename });
  if (error || !data) return NextResponse.json({ error: 'unavailable' }, { status: 502 });
  return NextResponse.redirect(data.signedUrl, 302);
}
