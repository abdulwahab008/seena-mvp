'use client';

import { formatInt, formatPaisa } from '@/lib/reports/pdf-layout';

export type GridColumn = { key: string; label: string; type: string };
export type GridRow = Record<string, string | number | boolean | null>;

function cell(type: string, v: string | number | boolean | null): string {
  if (v === null || v === undefined) return '—';
  if (type === 'money' && typeof v === 'number') return formatPaisa(v);
  if (type === 'int' && typeof v === 'number') return formatInt(v);
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  return String(v);
}

export function ReportGrid({ columns, rows }: { columns: GridColumn[]; rows: GridRow[] }) {
  return (
    <div className="overflow-x-auto rounded-md border" data-testid="report-grid">
      <table className="w-full min-w-[640px] text-sm">
        <thead className="bg-muted/50 text-left">
          <tr>
            {columns.map((c) => (
              <th key={c.key} className="p-2">
                {c.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className="border-t" data-testid="report-row">
              {columns.map((c) => (
                <td key={c.key} className={`p-2 ${c.type === 'money' || c.type === 'int' || c.type === 'numeric' ? 'text-right tabular-nums' : ''}`}>
                  {cell(c.type, r[c.key] ?? null)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
