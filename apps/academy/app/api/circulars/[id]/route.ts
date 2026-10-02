import { NextRequest, NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id: circularId } = await params;
    if (!circularId) {
      return NextResponse.json({ error: 'Circular ID required' }, { status: 400 });
    }

    const supabase = await supabaseServer();

    const client = supabase as any;

    // Query circular - RLS automatically enforces:
    // 1. Staff permissions
    // 2. Parent visibility: status='published' AND publish_at <= now() AND child class/audience matching
    const { data: circular, error } = await client
      .from('circular')
      .select(`
        id,
        title,
        body_en,
        body_ur,
        publish_at,
        expires_at,
        status,
        created_at,
        circular_attachment (
          id,
          file_name,
          mime_type,
          size_bytes,
          storage_path
        )
      `)
      .eq('id', circularId)
      .maybeSingle();

    if (error || !circular) {
      // AC 3: RLS returns 0 rows, API responds 404
      return NextResponse.json({ error: 'Circular not found' }, { status: 404 });
    }

    return NextResponse.json({ circular }, { status: 200 });
  } catch (err: any) {
    return NextResponse.json({ error: err.message || 'Internal server error' }, { status: 500 });
  }
}
