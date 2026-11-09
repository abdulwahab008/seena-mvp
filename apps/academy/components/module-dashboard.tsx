import type { ReactNode } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export type Kpi = { id: string; label: string; value: ReactNode };
export type BreakdownRow = { key: string; label: ReactNode; value: number; display?: ReactNode };

export function KpiGrid({ prefix, kpis }: { prefix: string; kpis: Kpi[] }) {
  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
      {kpis.map((k) => (
        <Card key={k.id}>
          <CardHeader className="pb-1">
            <CardTitle className="text-sm font-normal text-muted-foreground">{k.label}</CardTitle>
          </CardHeader>
          <CardContent className="text-2xl font-semibold" data-testid={`${prefix}-kpi-${k.id}`}>
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
    <section className="space-y-2">
      <h2 className="font-medium">{title}</h2>
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">{empty}</p>
      ) : (
        rows.map((r) => (
          <div key={r.key} className="space-y-1 text-sm">
            <p className="flex justify-between gap-2">
              <span>{r.label}</span>
              <span className="text-muted-foreground">{r.display ?? r.value}</span>
            </p>
            {bars && (
              <div className="h-1.5 rounded-full bg-muted">
                <div className="h-1.5 rounded-full bg-primary" style={{ width: `${(Math.max(0, r.value) * 100) / max}%` }} />
              </div>
            )}
          </div>
        ))
      )}
    </section>
  );
}
