import { auth, currentUser } from '@clerk/nextjs/server';
import { db, schema } from './db';
import { and, asc, eq, isNull, sql } from 'drizzle-orm';

export type SessionContext = {
  userId: string;
  orgId: string;
  role: 'admin' | 'teacher';
  email: string;
};

/**
 * Resolve the Clerk session into our internal user + org IDs.
 * Idempotent: safe to call concurrently from layout + page server components.
 *
 * Uses ON CONFLICT upserts so racing inserts don't violate unique constraints.
 */
export async function requireSession(): Promise<SessionContext> {
  const { userId: clerkUserId, orgId: clerkOrgId, orgRole } = await auth();
  if (!clerkUserId) throw new Error('UNAUTHENTICATED');

  const cu = await currentUser();
  const email = cu?.emailAddresses[0]?.emailAddress ?? `${clerkUserId}@unknown.local`;
  const name = cu?.fullName ?? null;

  // Upsert user — keeps email/name in sync with Clerk on every sign-in.
  const [user] = await db
    .insert(schema.users)
    .values({ clerkId: clerkUserId, email, name })
    .onConflictDoUpdate({
      target: schema.users.clerkId,
      set: { email, name },
    })
    .returning();
  if (!user) throw new Error('FAILED_TO_RESOLVE_USER');

  // Resolve / upsert organization.
  let org;
  if (clerkOrgId) {
    [org] = await db
      .insert(schema.organizations)
      .values({ clerkOrgId, name: 'Workspace' })
      .onConflictDoUpdate({
        target: schema.organizations.clerkOrgId,
        set: { clerkOrgId: sql`EXCLUDED.clerk_org_id` },
      })
      .returning();
  } else {
    // Personal mode: find this user's own personal workspace (an org with no
    // Clerk org attached), or create one. Scoped to clerk_org_id IS NULL and
    // ordered deterministically so a membership row in a *shared* org —
    // including one Clerk has since removed this user from — can never be
    // picked up here; Clerk, not this table, is the source of truth for
    // shared-org access.
    const [existingMembership] = await db
      .select({ orgId: schema.memberships.orgId })
      .from(schema.memberships)
      .innerJoin(schema.organizations, eq(schema.organizations.id, schema.memberships.orgId))
      .where(and(eq(schema.memberships.userId, user.id), isNull(schema.organizations.clerkOrgId)))
      .orderBy(asc(schema.memberships.createdAt))
      .limit(1);
    if (existingMembership) {
      [org] = await db
        .select()
        .from(schema.organizations)
        .where(eq(schema.organizations.id, existingMembership.orgId));
    } else {
      [org] = await db
        .insert(schema.organizations)
        .values({ name: `${user.name ?? user.email}'s Workspace` })
        .returning();
    }
  }
  if (!org) throw new Error('FAILED_TO_RESOLVE_ORG');

  // Upsert membership. Clerk is authoritative for shared orgs on every call
  // (a demotion or removal in Clerk must take effect immediately, not just on
  // first insert); personal workspaces have no Clerk role to defer to, so
  // their sole member is always admin.
  const desiredRole: 'admin' | 'teacher' = !clerkOrgId || orgRole === 'org:admin' ? 'admin' : 'teacher';
  const [membership] = await db
    .insert(schema.memberships)
    .values({ userId: user.id, orgId: org.id, role: desiredRole })
    .onConflictDoUpdate({
      target: [schema.memberships.userId, schema.memberships.orgId],
      set: { role: desiredRole },
    })
    .returning();
  if (!membership) throw new Error('FAILED_TO_RESOLVE_MEMBERSHIP');

  return { userId: user.id, orgId: org.id, role: membership.role, email: user.email };
}
