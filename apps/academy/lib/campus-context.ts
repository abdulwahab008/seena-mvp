import { cookies } from 'next/headers';

export const ACTIVE_CAMPUS_COOKIE = 'sa_campus';

// A school with more than one campus picks the campus it is working on in the header; every
// campus-scoped screen reads that choice here instead of silently taking the first campus.
// The cookie is only a preference: a value the user can no longer see falls back to the first.
export async function pickActiveCampus<T extends { id: string }>(campuses: T[] | null | undefined): Promise<T | undefined> {
  if (!campuses?.length) return undefined;
  const chosen = (await cookies()).get(ACTIVE_CAMPUS_COOKIE)?.value;
  return campuses.find((c) => c.id === chosen) ?? campuses[0];
}

type SessionRow = { id: string; is_current?: boolean | null; campus_id?: string | null };

// The session a campus-scoped screen works in: the campus's own current session, then a
// tenant-wide current one. Never another campus's session.
export function pickSessionForCampus<T extends SessionRow>(sessions: T[] | null | undefined, campusId: string | undefined): T | undefined {
  const mine = (sessions ?? []).filter((s) => s.campus_id === undefined || s.campus_id === null || s.campus_id === campusId);
  return mine.find((s) => s.is_current && s.campus_id === campusId) ?? mine.find((s) => s.is_current) ?? mine[0];
}
