// @vitest-environment node
import { describe, expect, it } from 'vitest';
import { readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { NAV_SECTIONS } from './navigation';

const APP_DIR = path.resolve(__dirname, '../app/(app)');

/** Every static route under app/(app) that has a page, e.g. /payroll/runs. */
function staticRoutes(dir: string, segments: string[] = []): string[] {
  const found: string[] = [];
  if (existsSync(path.join(dir, 'page.tsx')) && segments.length > 0) {
    found.push('/' + segments.join('/'));
  }
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const name = entry.name;
    // dynamic detail pages are reached from a list; route groups add no path segment
    if (name.startsWith('[')) continue;
    const isGroup = name.startsWith('(') && name.endsWith(')');
    found.push(...staticRoutes(path.join(dir, name), isGroup ? segments : [...segments, name]));
  }
  return found;
}

// Pages that are deliberately not in the sidebar: reached from the header, or from a page of their own.
const REACHED_ELSEWHERE = new Set(['/account', '/exams/mastery/capture']);

describe('sidebar', () => {
  const hrefs = new Set(NAV_SECTIONS.flatMap((s) => s.items.map((i) => i.href)));

  it('links to every page a staff member can use', () => {
    const orphans = staticRoutes(APP_DIR).filter((r) => !hrefs.has(r) && !REACHED_ELSEWHERE.has(r));
    expect(orphans).toEqual([]);
  });

  it('only links to pages that exist', () => {
    const routes = new Set(staticRoutes(APP_DIR));
    const dead = [...hrefs].filter((h) => !routes.has(h));
    expect(dead).toEqual([]);
  });
});
