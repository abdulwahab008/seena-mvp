import { clerkMiddleware, createRouteMatcher } from '@clerk/nextjs/server';

const isProtectedRoute = createRouteMatcher([
  '/dashboard(.*)',
  '/books(.*)',
  '/exams(.*)',
  '/chat(.*)',
  '/settings(.*)',
  '/bank(.*)',
  '/api/books(.*)',
  '/api/exams(.*)',
  '/api/chat(.*)',
  '/api/patterns(.*)',
  '/api/submissions(.*)',
  '/api/bank(.*)',
  '/api/org(.*)',
]);

export default clerkMiddleware(async (auth, req) => {
  if (isProtectedRoute(req)) {
    // Page routes send signed-out users to sign-in; API routes get a 404/401.
    if (req.nextUrl.pathname.startsWith('/api')) {
      await auth.protect();
    } else {
      await auth.protect({ unauthenticatedUrl: new URL('/sign-in', req.url).toString() });
    }
  }
});

export const config = {
  matcher: [
    '/((?!_next|[^?]*\\.(?:html?|css|js(?!on)|jpe?g|webp|png|gif|svg|ttf|woff2?|ico|csv|docx?|xlsx?|zip|webmanifest)).*)',
    '/(api|trpc)(.*)',
  ],
};
