import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';

/**
 * POST-only: a GET sign-out can be triggered by any <img> or prefetch on a page
 * the user is merely reading, and browsers pre-fetch links.
 */
export async function POST(request: NextRequest) {
  const supabase = await supabaseServer();
  await supabase.auth.signOut();

  const url = new URL('/login', request.url);
  url.searchParams.set('signed_out', '1');

  // 303 so the browser turns the POST into a GET for the redirect.
  return NextResponse.redirect(url, { status: 303 });
}
