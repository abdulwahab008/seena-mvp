import type { Database } from './database.types';

type AppRole = Database['public']['Enums']['app_role'];

// FR-A12: mirrors the `app.auth_role() not in ('super_admin', 'owner')`
// bypass repeated across every campus-scoped RLS policy and RPC
// (tenant_isolation_hardening.sql onward). super_admin/owner access is
// role-based, never gated by public.user_campus rows — so an empty
// user_campus set means something very different for them (normal; they
// were never meant to be there) than for every other role (misconfigured;
// they have no data anywhere).
const TENANT_WIDE_ROLES: ReadonlySet<AppRole> = new Set(['super_admin', 'owner']);

export function isTenantWideRole(role: AppRole): boolean {
  return TENANT_WIDE_ROLES.has(role);
}

// AC4: "Given a user with zero campuses in scope, when they log in, they
// see a 'no campus assigned' screen." Only applies to campus-scoped roles
// — a tenant-wide role with zero user_campus rows is the expected steady
// state, not a misconfiguration.
export function hasNoCampusAssigned(role: AppRole, activeCampusCount: number): boolean {
  return !isTenantWideRole(role) && activeCampusCount <= 0;
}

export type CampusOption = { id: string; code: string; name: string };

export const ALL_CAMPUSES_VALUE = '';

// AC2: "the campus filter offers 4 options plus 'All campuses'" — one
// option per campus the caller can see, plus a sentinel "All campuses"
// entry whenever there's at least one campus to aggregate across.
export function buildCampusFilterOptions(campuses: CampusOption[]): Array<{ value: string; label: string }> {
  const options = campuses.map((c) => ({ value: c.id, label: `${c.name} (${c.code})` }));
  if (campuses.length > 0) {
    options.push({ value: ALL_CAMPUSES_VALUE, label: 'All campuses' });
  }
  return options;
}
