import { auth, currentUser } from '@clerk/nextjs/server';
import { db, schema } from './db';
import { and, eq, sql } from 'drizzle-orm';

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
    // Personal mode: find existing membership, or create a personal workspace.
    const [existingMembership] = await db
      .select({ orgId: schema.memberships.orgId })
      .from(schema.memberships)
      .where(eq(schema.memberships.userId, user.id))
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

  // Upsert membership — admin by default for personal/first-org case.
  const desiredRole: 'admin' | 'teacher' = orgRole === 'org:admin' ? 'admin' : 'admin';
  await db
    .insert(schema.memberships)
    .values({ userId: user.id, orgId: org.id, role: desiredRole })
    .onConflictDoNothing();

  // Re-read membership for authoritative role (in case Clerk role changed).
  const [membership] = await db
    .select()
    .from(schema.memberships)
    .where(and(eq(schema.memberships.userId, user.id), eq(schema.memberships.orgId, org.id)));

  const role: 'admin' | 'teacher' =
    orgRole === 'org:admin' || membership?.role === 'admin' ? 'admin' : 'teacher';

  return { userId: user.id, orgId: org.id, role, email: user.email };
}
