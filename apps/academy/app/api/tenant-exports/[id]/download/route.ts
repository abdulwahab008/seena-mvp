import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

// FR-A19: the signed download link. The database decides who may download and whether the
// link is still alive (72 hours from completion); a lapsed link answers 410 EXPORT_LINK_EXPIRED
// and a new request has to be made. The redirect target is a short-lived storage URL minted
// here with the service role, after the checks.
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!z.string().uuid().safeParse(id).success) return NextResponse.json({ code: 'EXPORT_NOT_FOUND' }, { status: 404 });

  const supabase = await supabaseServer();
  const { data: user } = await supabase.auth.getUser();
  if (!user.user) return NextResponse.json({ code: 'UNAUTHENTICATED' }, { status: 401 });

  const { data: path, error } = await supabase.rpc('get_tenant_export_download', { p_id: id });
  if (error) {
    if (error.message.includes('PERMISSION_DENIED')) return NextResponse.json({ code: 'PERMISSION_DENIED' }, { status: 403 });
    if (error.message.includes('EXPORT_LINK_EXPIRED')) return NextResponse.json({ code: 'EXPORT_LINK_EXPIRED', message: 'This download link has expired. Request a new export.' }, { status: 410 });
    if (error.message.includes('EXPORT_NOT_FOUND')) return NextResponse.json({ code: 'EXPORT_NOT_FOUND' }, { status: 404 });
    if (error.message.includes('EXPORT_NOT_READY')) return NextResponse.json({ code: 'EXPORT_NOT_READY' }, { status: 409 });
    return NextResponse.json({ code: 'ERROR' }, { status: 500 });
  }

  const { data: signed, error: signError } = await supabaseServiceRole().storage.from('tenant-exports').createSignedUrl(path, 60, { download: `school-data-export-${id.slice(0, 8)}.zip` });
  if (signError || !signed) return NextResponse.json({ code: 'EXPORT_LINK_EXPIRED', message: 'The archive has been deleted. Request a new export.' }, { status: 410 });
  return NextResponse.redirect(signed.signedUrl, 302);
}
