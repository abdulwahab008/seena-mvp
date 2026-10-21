// @vitest-environment node
import { describe, expect, it } from 'vitest';
import { readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { NAV_SECTIONS, navSectionsForRole } from './navigation';
import { canOpenFeesPath } from './auth/fee-access';

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

const ALL_ROLES = [
  'super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'accountant', 'exam_controller',
  'head_of_department', 'class_teacher', 'subject_teacher', 'hr_manager', 'librarian', 'transport_manager',
  'receptionist', 'nurse', 'parent', 'student', 'none',
];

describe('the Fees section', () => {
  const feeItems = NAV_SECTIONS.find((s) => s.id === 'fees')!.items;

  it('lists exactly the pages each role is allowed to open', () => {
    for (const role of ALL_ROLES) {
      const shown = navSectionsForRole(NAV_SECTIONS, role).find((s) => s.id === 'fees')?.items.map((i) => i.href) ?? [];
      const allowed = feeItems.map((i) => i.href).filter((href) => canOpenFeesPath(role, href));
      expect(shown, role).toEqual(allowed);
    }
  });

  it('is not in the sidebar of a teacher, a librarian or a nurse', () => {
    for (const role of ['class_teacher', 'subject_teacher', 'librarian', 'nurse', 'hr_manager', 'vice_principal']) {
      expect(navSectionsForRole(NAV_SECTIONS, role).some((s) => s.id === 'fees'), role).toBe(false);
    }
  });

  it('shows an accountant every fees page and an admissions officer two', () => {
    expect(navSectionsForRole(NAV_SECTIONS, 'accountant').find((s) => s.id === 'fees')!.items).toHaveLength(feeItems.length);
    expect(navSectionsForRole(NAV_SECTIONS, 'admissions_officer').find((s) => s.id === 'fees')!.items.map((i) => i.href)).toEqual([
      '/fees/concessions',
      '/fees/sibling-discounts',
    ]);
  });

  it('hides the restricted items when the role is unknown, and shows everything else', () => {
    const none = navSectionsForRole(NAV_SECTIONS, undefined);
    expect(none.some((s) => s.id === 'fees')).toBe(false);
    expect(none.some((s) => s.id === 'overview')).toBe(true);
  });
});
