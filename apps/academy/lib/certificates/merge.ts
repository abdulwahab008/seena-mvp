/**
 * FR-T01: the merge-field half of the certificate template designer.
 *
 * The authoritative validation lives in the database
 * (public.certificate_merge_fields / validate_certificate_template, in
 * supabase/migrations/20260731860000_certificate_template_designer.sql) —
 * activation is what binds a template to a board document, and that gate
 * cannot live in a browser. This module exists because the same rules are
 * needed in two other places where a round-trip is the wrong shape:
 *
 *   * the designer, which shows the Principal an offending field WHILE she
 *     is typing rather than after she clicks Activate;
 *   * the renderer, which has to substitute the values.
 *
 * The pattern below is deliberately identical to the SQL one, including
 * matching ANY `{{...}}` token rather than only well-formed field paths:
 * a typo has to surface as an unknown field, not survive as a literal
 * brace pair printed on a certificate.
 */

const MERGE_FIELD_PATTERN = /\{\{([^{}]*)\}\}/g;

export type CatalogField = {
  field_path: string;
  required: boolean;
  label_en: string;
};

export type MergeFieldReport = {
  used: string[];
  unknown: string[];
  missingRequired: string[];
  ok: boolean;
};

/** Every distinct token the body references, trimmed and sorted. */
export function extractMergeFields(bodyHtml: string): string[] {
  const found = new Set<string>();
  for (const match of bodyHtml.matchAll(MERGE_FIELD_PATTERN)) found.add(match[1]!.trim());
  return [...found].sort();
}

export function validateMergeFields(bodyHtml: string, catalog: readonly CatalogField[]): MergeFieldReport {
  const allowed = new Set(catalog.map((f) => f.field_path));
  const used = extractMergeFields(bodyHtml);
  const unknown = used.filter((f) => !allowed.has(f));
  const missingRequired = catalog.filter((f) => f.required && !used.includes(f.field_path)).map((f) => f.field_path).sort();
  return { used, unknown, missingRequired, ok: unknown.length === 0 && missingRequired.length === 0 };
}

export function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/**
 * The template body is authored HTML and is emitted as-is; only the
 * substituted VALUES are escaped, since those come from student records
 * and an apostrophe or an ampersand in a father's name must not be able to
 * rewrite the document around it.
 *
 * A field with no value renders as its own path in brackets rather than as
 * nothing: on a preview of a draft that is exactly the feedback the author
 * needs, and on an issued certificate a visible gap is safer than a
 * silently missing statutory field.
 */
export function applyMergeFields(bodyHtml: string, values: Readonly<Record<string, string | null | undefined>>): string {
  return bodyHtml.replace(MERGE_FIELD_PATTERN, (_whole, raw: string) => {
    const key = raw.trim();
    const value = values[key];
    return escapeHtml(value ?? `[${key}]`);
  });
}
