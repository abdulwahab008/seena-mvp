// CSV shape for linking fathers to students already on the register (import_guardian_contacts).
export const GUARDIAN_IMPORT_COLUMNS = ['gr_number', 'father_name', 'father_cnic', 'father_phone'] as const;

export const GUARDIAN_IMPORT_TEMPLATE = `${GUARDIAN_IMPORT_COLUMNS.join(',')}\n1001,Muhammad Asif,35202-1234567-1,0300 1234567\n`;

export type GuardianImportRow = { row: number; gr_number: string; father_name: string; father_cnic: string; father_phone: string };

export function toGuardianImportRows(matrix: string[][]): { ok: true; rows: GuardianImportRow[] } | { ok: false; message: string } {
  const header = (matrix[0] ?? []).map((h) => h.trim().toLowerCase());
  const unknown = header.filter((h) => h && !(GUARDIAN_IMPORT_COLUMNS as readonly string[]).includes(h));
  if (!header.includes('gr_number') || !(header.includes('father_cnic') || header.includes('father_phone')) || unknown.length) {
    return {
      ok: false,
      message: `Use the columns ${GUARDIAN_IMPORT_COLUMNS.join(', ')}: gr_number plus the father's CNIC or phone.${unknown.length ? ` Not recognised: ${unknown.join(', ')}.` : ''}`,
    };
  }
  const at = (cells: string[], name: string) => (cells[header.indexOf(name)] ?? '').trim();
  const rows = matrix
    .slice(1)
    .map((cells, i) => ({ row: i + 2, gr_number: at(cells, 'gr_number'), father_name: at(cells, 'father_name'), father_cnic: at(cells, 'father_cnic'), father_phone: at(cells, 'father_phone') }))
    .filter((r) => r.gr_number || r.father_cnic || r.father_phone);
  return { ok: true, rows };
}
