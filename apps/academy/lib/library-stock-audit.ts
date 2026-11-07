export type AuditCopy = { barcode: string; status: string; title: string; accession_no: string; shelf: string | null };

export type AuditResult = {
  found: number;
  missing: AuditCopy[];
  notAvailable: AuditCopy[];
  unknown: string[];
};

// Compare what was scanned on the shelves with the register: every copy the
// register says is on the shelf ('available') but was not scanned is missing; a
// scanned copy the register says is out (issued, lost...) needs checking in;
// a scanned code that is not a copy at all is unknown.
export function compareStock(scanned: string[], copies: AuditCopy[]): AuditResult {
  const seen = new Set(scanned.map((s) => s.trim().toUpperCase()).filter(Boolean));
  const byCode = new Map(copies.map((c) => [c.barcode.trim().toUpperCase(), c]));
  const missing = copies.filter((c) => c.status === 'available' && !seen.has(c.barcode.trim().toUpperCase()));
  const notAvailable: AuditCopy[] = [];
  const unknown: string[] = [];
  let found = 0;
  for (const code of seen) {
    const copy = byCode.get(code);
    if (!copy) unknown.push(code);
    else if (copy.status === 'available') found++;
    else notAvailable.push(copy);
  }
  return { found, missing, notAvailable, unknown };
}
