/**
 * Open-redirect guard for the `?redirectTo=` round trip.
 *
 * Everything here is attacker-controlled: the value arrives in a query string
 * on an unauthenticated page, so a phishing link like
 * `/login?redirectTo=https://evil.example` must never survive to a
 * post-sign-in `router.push()`.
 *
 * The rule is deliberately strict — a single leading slash, then a path.
 * Anything else falls back to the caller's default.
 */
const DEFAULT_DESTINATION = '/dashboard';

/**
 * Header middleware stamps on every request so a Server Component can learn
 * the current path — Next gives layouts no other way to see it.
 *
 * Declared here rather than in middleware.ts so that importing it from a
 * layout does not pull the whole edge-runtime middleware module (and its
 * @supabase/ssr import) into the Node server bundle.
 */
export const PATHNAME_HEADER = 'x-pathname';

const AUTH_PATHS = new Set([
  '/login',
  '/login/otp',
  '/sign-up',
  '/forgot-password',
  '/reset-password',
  '/no-school',
]);

/** True for any space, tab, newline or C0/DEL control character. */
function hasControlOrSpace(value: string): boolean {
  for (const char of value) {
    const code = char.codePointAt(0)!;
    if (code <= 0x20 || code === 0x7f) return true;
  }
  return false;
}

export function safeRedirectTo(
  value: string | null | undefined,
  fallback = DEFAULT_DESTINATION,
): string {
  if (!value) return fallback;

  // Reject anything not starting with exactly one "/". This kills absolute
  // URLs ("https://evil"), scheme-relative URLs ("//evil.example", which a
  // browser treats as absolute), and the backslash variants some parsers
  // normalise to "//" ("/\evil.example").
  if (!value.startsWith('/')) return fallback;
  if (value.startsWith('//') || value.startsWith('/\\')) return fallback;

  // A control character or raw whitespace can be used to smuggle the value
  // past a naive check further down the stack.
  if (hasControlOrSpace(value)) return fallback;

  // Never bounce back into an auth page — it would loop.
  const path = value.split(/[?#]/)[0] ?? value;
  if (AUTH_PATHS.has(path)) return fallback;

  return value;
}

/** Builds the `/login?redirectTo=…` URL a protected surface redirects to. */
export function loginUrlFor(pathname: string, search = ''): string {
  const safe = safeRedirectTo(`${pathname}${search}`, '');
  return safe ? `/login?redirectTo=${encodeURIComponent(safe)}` : '/login';
}
