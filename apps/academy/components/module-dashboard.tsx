import Link from 'next/link';
import type { ReactNode } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export type Kpi = { id: string; label: string; value: ReactNode };
export type BreakdownRow = { key: string; label: ReactNode; value: number; display?: ReactNode; href?: string };

export function KpiGrid({ prefix, kpis }: { prefix: string; kpis: Kpi[] }) {
  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
      {kpis.map((k) => (
        <Card key={k.id}>
          <CardHeader className="p-4 pb-1">
            <CardTitle className="text-sm font-normal text-muted-foreground">{k.label}</CardTitle>
          </CardHeader>
          <CardContent className="p-4 pt-0 text-2xl font-semibold tabular-nums" data-testid={`${prefix}-kpi-${k.id}`}>
            {k.value}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

export function Breakdown({ title, rows, empty, bars = false }: { title: string; rows: BreakdownRow[]; empty: string; bars?: boolean }) {
  const max = Math.max(1, ...rows.map((r) => r.value));
  return (
    <Card>
      <CardHeader className="p-4 pb-2">
        <CardTitle className="text-base">{title}</CardTitle>
      </CardHeader>
      <CardContent className="p-2 pt-0">
        {rows.length === 0 ? (
          <p className="px-2 pb-2 text-sm text-muted-foreground">{empty}</p>
        ) : (
          <ul>
            {rows.map((r) => {
              const body = (
                <>
                  <span className="flex justify-between gap-2">
                    <span>{r.label}</span>
                    <span className="tabular-nums text-muted-foreground">{r.display ?? r.value}</span>
                  </span>
                  {bars && (
                    <span className="mt-1.5 block h-1.5 rounded-full bg-muted">
                      <span className="block h-1.5 rounded-full bg-primary/70" style={{ width: `${(Math.max(0, r.value) * 100) / max}%` }} />
                    </span>
                  )}
                </>
              );
              return (
                <li key={r.key} className="text-sm">
                  {r.href ? (
                    <Link href={r.href} className="block rounded-md px-2 py-1.5 transition-colors hover:bg-muted">
                      {body}
                    </Link>
                  ) : (
                    <div className="px-2 py-1.5">{body}</div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
