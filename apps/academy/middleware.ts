import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { loginUrlFor, PATHNAME_HEADER } from '@/lib/auth/redirect';

/**
 * Refreshes the Supabase auth session cookie on every request (per
 * @supabase/ssr's documented Next.js pattern) so a Server Component never
 * sees a stale/expired token, AND gates every non-public route.
 *
 * The gate is DEFAULT-DENY: anything not matched by PUBLIC_ROUTES below needs
 * a session. Layout-level checks alone were not enough —
 *
 *   - Layouts do not run for route handlers, so every `app/**\/route.ts` sat
 *     outside (app)/layout.tsx's redirect no matter where it lived in the
 *     tree (app/(app)/students/import/template/route.ts was exactly this).
 *   - A new page added under app/(app)/ is only protected for as long as
 *     nobody moves it; a new top-level directory is not protected at all.
 *
 * Layout checks stay where they are — they still own the tenant/campus rules
 * this file has no business knowing — but they are now the second layer
 * rather than the only one.
 */

/** Exact paths reachable with no session. */
const PUBLIC_PATHS = new Set([
  '/',
  '/login',
  '/login/otp',
  '/sign-up',
  '/forgot-password',
  '/reset-password',
  '/api/auth/sign-out',
]);

/**
 * Prefixes reachable with no session, each for a specific reason:
 *  - /apply, /api/public-enquiry  — the public admissions form (FR-B02);
 *    fn_public_school_info / submit_public_enquiry are granted to anon.
 *  - /accept-invite, /guardian/activate — pre-account surfaces; the visitor
 *    cannot have a session yet, and the URL token is the credential.
 *  - /admin/provision — bootstrap tenant creation, gated by ADMIN_SETUP_TOKEN
 *    in its action. It cannot require a session: it is what creates the first
 *    account there is.
 *  - /api/branding-asset — deliberately session-less signed-URL minting
 *    (FR-A18 AC5), asserted by e2e/tenant-branding-assets.spec.ts.
 */
const PUBLIC_PREFIXES = [
  '/apply/',
  '/accept-invite/',
  '/guardian/activate/',
  '/admin/provision',
  '/api/public-enquiry/',
  '/api/branding-asset/',
  '/api/calendar/feed/',
  '/api/webhooks/',
];

function isPublic(pathname: string) {
  if (PUBLIC_PATHS.has(pathname)) return true;
  return PUBLIC_PREFIXES.some((prefix) => pathname === prefix || pathname.startsWith(prefix));
}

export async function middleware(request: NextRequest) {
  const { pathname, search } = request.nextUrl;

  const requestHeaders = new Headers(request.headers);
  requestHeaders.set(PATHNAME_HEADER, `${pathname}${search}`);
  const nextArg = { request: { headers: requestHeaders } };

  let response = NextResponse.next(nextArg);

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookiesToSet) => {
          for (const { name, value } of cookiesToSet) request.cookies.set(name, value);
          response = NextResponse.next(nextArg);
          for (const { name, value, options } of cookiesToSet) {
            response.cookies.set(name, value, options);
          }
        },
      },
    },
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user && !isPublic(pathname)) {
    // A fetch/XHR wants a status it can branch on, not an HTML login page.
    if (pathname.startsWith('/api/')) {
      return NextResponse.json(
        { error: 'Authentication required.' },
        { status: 401, headers: { 'Cache-Control': 'no-store' } },
      );
    }
    return NextResponse.redirect(new URL(loginUrlFor(pathname, search), request.url));
  }

  // Back-button protection. Without this, bfcache/history serves the last
  // authenticated render of a protected page after sign-out — the session is
  // gone, but the screenshot of the app is still there, including whatever
  // student or fee data was on it. `no-store` forces a real request, which
  // then hits the redirect above.
  if (!isPublic(pathname)) {
    response.headers.set('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
    response.headers.set('Pragma', 'no-cache');
  }

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)'],
};
