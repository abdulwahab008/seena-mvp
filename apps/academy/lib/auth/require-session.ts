import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import type { User } from '@supabase/supabase-js';
import { supabaseServer } from '../supabase/server';
import { loginUrlFor, PATHNAME_HEADER } from './redirect';

/**
 * Layout-level session guard, and the second of the two layers protecting an
 * authenticated surface — middleware.ts is the first.
 *
 * It is not redundant with middleware: middleware runs before the request is
 * routed and cannot know what a given layout needs, while this one also
 * resolves tenant membership and sends a membership-less account to
 * /no-school rather than into an app shell where every query returns nothing.
 * It is also what still fires if a session expires between the middleware
 * check and the render.
 */
export async function requireSession(): Promise<User> {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    // Middleware normally handles this and sets ?redirectTo itself; reaching
    // here means the session died mid-render, so rebuild the same URL from
    // the path middleware stamped on the request.
    const target = (await headers()).get(PATHNAME_HEADER) ?? '';
    const [pathname, search] = target.split('?');
    redirect(pathname ? loginUrlFor(pathname, search ? `?${search}` : '') : '/login');
  }

  return user;
}
