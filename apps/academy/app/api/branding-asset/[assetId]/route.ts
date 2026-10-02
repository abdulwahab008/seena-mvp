import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';

// FR-A18 AC5: a parent with no session can still render a branding image
// (the future report-card PDF viewer's use case) via a signed link — the
// branding bucket is private, so this route, not a public bucket, is the
// only path to it. assetId is an unguessable uuid; the service-role
// client is required only to bypass storage.objects RLS for a caller
// that carries no JWT at all.
export async function GET(_request: NextRequest, { params }: { params: Promise<{ assetId: string }> }) {
  const { assetId } = await params;
  const admin = supabaseServiceRole();

  const { data: asset, error: fetchError } = await admin.from('branding_asset').select('storage_path').eq('id', assetId).maybeSingle();
  if (fetchError || !asset) return NextResponse.json({ error: 'Asset not found.' }, { status: 404 });

  const { data, error } = await admin.storage.from('branding').createSignedUrl(asset.storage_path, 900);
  if (error || !data) return NextResponse.json({ error: 'Could not generate a signed URL.' }, { status: 500 });

  return NextResponse.json({ url: data.signedUrl }, { status: 200 });
}
