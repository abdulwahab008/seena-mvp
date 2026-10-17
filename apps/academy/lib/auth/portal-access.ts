/**
 * Who belongs in the parent portal.
 *
 * The portal pages (/portal/*) decide which children to show with a plain
 * `from('enrolment').select(...)` and rely on row-level security to have already
 * narrowed the result to the caller's own children. That holds for a guardian,
 * whose policies are scoped through student_guardian. It does not hold for staff:
 * their enrolment policy is scoped by campus, so a staff session that simply typed
 * /portal/fees saw every enrolled student in the campus as "their children" and the
 * real fee balance of whichever came first.
 *
 * The portal layout therefore asks this module where a session belongs and sends
 * everyone who is not a guardian home before any portal page renders. The role is
 * read from the signed token (the same claim the database policies read), never from
 * a cookie or a query string.
 */

/** Where a staff session lands when it wanders into a portal URL. */
const STAFF_HOME = '/dashboard';
/** Where a student session lands: the portal that is theirs. */
const STUDENT_HOME = '/student/timetable';
/** A session with credentials but no school (or an unknown role). */
const NO_SCHOOL = '/no-school';

/**
 * `null` means "stay: this session is a guardian". Anything else is the path the
 * session should be sent to instead.
 *
 * A role of `'none'` (or a missing claim) is not sent straight to /no-school by the
 * layout: a guardian whose token was minted before they were linked to a child also
 * carries `'none'` until it refreshes, so the layout checks for a guardian row first.
 */
export function portalRedirectFor(appRole: unknown): string | null {
  if (appRole === 'parent') return null;
  if (appRole === 'student') return STUDENT_HOME;
  if (appRole === undefined || appRole === null || appRole === '' || appRole === 'none') return NO_SCHOOL;
  return STAFF_HOME;
}

/** True when the redirect target means "no usable role", the one case that deserves a second look. */
export function isNoSchoolRedirect(target: string): boolean {
  return target === NO_SCHOOL;
}
