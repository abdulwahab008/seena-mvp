import type { NavSection } from './navigation';

export type FeatureSet = Record<string, boolean>;

/**
 * FR-A17 AC5: "when the flag service is unreachable, the last-known-good
 * cached set is used and the failure is logged". The flags live in Postgres,
 * so "unreachable" here means the resolve query failed — a dropped
 * connection, a timeout, a transient PostgREST error. Failing that read
 * closed would black out every gated module across the product for the
 * duration of a blip, which is a far worse outcome than briefly serving a
 * stale flag set.
 *
 * Scoped per tenant and held in module state, so it lives as long as the
 * server process. Not a substitute for the database: the RLS policies and
 * write triggers still resolve live on every statement, so a stale cache can
 * only ever leave a nav item showing — the module underneath it is still
 * gated.
 */
const lastKnownGood = new Map<string, FeatureSet>();

export type FeatureResolution = { features: FeatureSet; stale: boolean };

export function cacheFeatures(tenantId: string, features: FeatureSet): void {
  lastKnownGood.set(tenantId, features);
}

export function cachedFeatures(tenantId: string): FeatureSet | undefined {
  return lastKnownGood.get(tenantId);
}

/**
 * Turns a resolve outcome into the set to render with. A failure falls back
 * to the last good set for that tenant; with no cache at all — the very first
 * request after a restart — an empty set is returned, which reads as "no
 * optional module is on" rather than as an outage.
 */
export function resolveFeatureSet(
  tenantId: string,
  resolved: unknown,
  error: unknown,
): FeatureResolution {
  if (!error && resolved && typeof resolved === 'object') {
    const features = Object.fromEntries(
      Object.entries(resolved as Record<string, unknown>).map(([code, on]) => [code, on === true]),
    );
    cacheFeatures(tenantId, features);
    return { features, stale: false };
  }

  return { features: lastKnownGood.get(tenantId) ?? {}, stale: true };
}

/** AC5's "and the failure is logged". */
export function logFeatureResolveFailure(tenantId: string, error: unknown): void {
  const detail =
    error && typeof error === 'object' && 'message' in error ? String((error as { message: unknown }).message) : 'no rows returned';
  console.error(`[features] could not resolve flags for tenant ${tenantId}, serving last known good: ${detail}`);
}

export function isFeatureEnabled(features: FeatureSet, code: string | undefined): boolean {
  if (!code) return true;
  return features[code] === true;
}

/**
 * Drops nav items whose feature is off, and any section left with nothing in
 * it. Hiding the link is presentation only — the route's own page and every
 * RPC behind it are gated in the database.
 */
export function visibleNavSections(sections: NavSection[], features: FeatureSet): NavSection[] {
  return sections
    .map((section) => ({
      ...section,
      items: section.items.filter((item) => isFeatureEnabled(features, item.feature)),
    }))
    .filter((section) => section.items.length > 0);
}
