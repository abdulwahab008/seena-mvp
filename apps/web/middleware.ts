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
]);

export default clerkMiddleware(async (auth, req) => {
  if (isProtectedRoute(req)) {
    await auth.protect();
  }
});

export const config = {
  matcher: [
    '/((?!_next|[^?]*\\.(?:html?|css|js(?!on)|jpe?g|webp|png|gif|svg|ttf|woff2?|ico|csv|docx?|xlsx?|zip|webmanifest)).*)',
    '/(api|trpc)(.*)',
  ],
};
