import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { Home } from 'lucide-react';
import {
  cacheFeatures,
  cachedFeatures,
  isFeatureEnabled,
  logFeatureResolveFailure,
  resolveFeatureSet,
  visibleNavSections,
} from './features';
import type { NavSection } from './navigation';

const SECTIONS: NavSection[] = [
  {
    id: 'academics',
    label: 'Academics',
    icon: Home,
    items: [
      { href: '/homework', label: 'Homework', feature: 'module.homework' },
      { href: '/exams/terms', label: 'Exam Terms' },
    ],
  },
  {
    id: 'expenses',
    label: 'Expenses',
    icon: Home,
    items: [
      { href: '/expenses/vouchers', label: 'Vouchers', feature: 'module.expenses' },
      { href: '/expenses/approvals', label: 'Approvals', feature: 'module.expenses' },
    ],
  },
];

describe('isFeatureEnabled', () => {
  it('treats an item with no feature code as always visible', () => {
    expect(isFeatureEnabled({}, undefined)).toBe(true);
  });

  it('is false for a code missing from the resolved set — an unknown flag is off', () => {
    expect(isFeatureEnabled({ 'module.homework': true }, 'module.transport')).toBe(false);
  });

  it('reads the resolved boolean', () => {
    expect(isFeatureEnabled({ 'module.homework': false }, 'module.homework')).toBe(false);
    expect(isFeatureEnabled({ 'module.homework': true }, 'module.homework')).toBe(true);
  });
});

describe('visibleNavSections', () => {
  it('AC1: hides the item whose module is off and keeps ungated siblings', () => {
    const visible = visibleNavSections(SECTIONS, {
      'module.homework': false,
      'module.expenses': true,
    });
    const academics = visible.find((s) => s.id === 'academics')!;
    expect(academics.items.map((i) => i.label)).toEqual(['Exam Terms']);
  });

  it('drops a section entirely once every item in it is gated off', () => {
    const visible = visibleNavSections(SECTIONS, {
      'module.homework': true,
      'module.expenses': false,
    });
    expect(visible.map((s) => s.id)).toEqual(['academics']);
  });

  it('keeps everything when every module is on', () => {
    const visible = visibleNavSections(SECTIONS, {
      'module.homework': true,
      'module.expenses': true,
    });
    expect(visible.flatMap((s) => s.items)).toHaveLength(4);
  });

  it('does not mutate the source sections', () => {
    visibleNavSections(SECTIONS, { 'module.homework': false, 'module.expenses': false });
    expect(SECTIONS[0]!.items).toHaveLength(2);
  });
});

describe('resolveFeatureSet', () => {
  beforeEach(() => {
    cacheFeatures('t1', {});
  });

  it('coerces the jsonb payload to booleans and caches it', () => {
    const { features, stale } = resolveFeatureSet('t1', { 'module.homework': true, 'module.expenses': false }, null);
    expect(stale).toBe(false);
    expect(features).toEqual({ 'module.homework': true, 'module.expenses': false });
    expect(cachedFeatures('t1')).toEqual(features);
  });

  it('treats anything that is not exactly true as off', () => {
    const { features } = resolveFeatureSet('t1', { a: 'true', b: 1, c: null, d: true }, null);
    expect(features).toEqual({ a: false, b: false, c: false, d: true });
  });

  // AC5: the resolve failed, so the last-known-good set is served rather than
  // blacking out every optional module.
  it('AC5: falls back to the last known good set on error and reports staleness', () => {
    resolveFeatureSet('t1', { 'module.homework': true }, null);
    const { features, stale } = resolveFeatureSet('t1', null, { message: 'connection reset' });
    expect(stale).toBe(true);
    expect(features).toEqual({ 'module.homework': true });
  });

  it('AC5: a failure with nothing cached yet yields an empty set, not a crash', () => {
    const { features, stale } = resolveFeatureSet('never-seen', null, { message: 'timeout' });
    expect(stale).toBe(true);
    expect(features).toEqual({});
  });

  it('does not overwrite the cache with a failed resolve', () => {
    resolveFeatureSet('t1', { 'module.expenses': true }, null);
    resolveFeatureSet('t1', null, { message: 'boom' });
    expect(cachedFeatures('t1')).toEqual({ 'module.expenses': true });
  });

  it('keeps each tenant cache separate', () => {
    resolveFeatureSet('t1', { 'module.homework': true }, null);
    resolveFeatureSet('t2', { 'module.homework': false }, null);
    expect(cachedFeatures('t1')).toEqual({ 'module.homework': true });
    expect(cachedFeatures('t2')).toEqual({ 'module.homework': false });
  });
});

describe('logFeatureResolveFailure', () => {
  let spy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    spy = vi.spyOn(console, 'error').mockImplementation(() => {});
  });
  afterEach(() => {
    spy.mockRestore();
  });

  it('AC5: logs the tenant and the underlying reason', () => {
    logFeatureResolveFailure('t1', { message: 'connection reset' });
    expect(spy).toHaveBeenCalledWith(expect.stringContaining('t1'));
    expect(spy).toHaveBeenCalledWith(expect.stringContaining('connection reset'));
  });

  it('still logs when there is no error object to explain the empty result', () => {
    logFeatureResolveFailure('t1', null);
    expect(spy).toHaveBeenCalledWith(expect.stringContaining('no rows returned'));
  });
});
