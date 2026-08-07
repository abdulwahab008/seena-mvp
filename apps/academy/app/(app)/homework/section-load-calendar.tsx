'use client';

import { useRouter } from 'next/navigation';
import { Label } from '@/components/ui/label';

type SectionOption = { sectionId: string; sectionLabel: string };
type LoadRow = { due_date: string; assignment_count: number; total_minutes: number };

function next14Days(): string[] {
  const days: string[] = [];
  const start = new Date();
  for (let i = 0; i < 14; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    days.push(d.toISOString().slice(0, 10));
  }
  return days;
}

export function SectionLoadCalendar({
  sections,
  selectedSectionId,
  rows,
}: {
  sections: SectionOption[];
  selectedSectionId: string;
  rows: LoadRow[];
}) {
  const router = useRouter();
  const byDate = new Map(rows.map((r) => [r.due_date, r]));

  return (
    <div className="space-y-2 rounded-lg border p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-medium">Section load — next 14 days</h2>
        {sections.length > 1 && (
          <div className="flex items-center gap-2">
            <Label htmlFor="load-section-picker" className="text-xs text-muted-foreground">
              Section
            </Label>
            <select
              id="load-section-picker"
              data-testid="load-section-picker"
              className="h-8 rounded-md border px-2 text-sm"
              value={selectedSectionId}
              onChange={(e) => router.push(`/homework?loadSection=${e.target.value}`)}
            >
              {sections.map((s) => (
                <option key={s.sectionId} value={s.sectionId}>
                  {s.sectionLabel}
                </option>
              ))}
            </select>
          </div>
        )}
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="p-2">Date</th>
              <th className="p-2">Assignments due</th>
              <th className="p-2">Est. minutes</th>
            </tr>
          </thead>
          <tbody>
            {next14Days().map((date) => {
              const row = byDate.get(date);
              return (
                <tr key={date} data-testid={`load-day-${date}`} className="border-b last:border-0">
                  <td className="p-2">{date}</td>
                  <td className="p-2">{row?.assignment_count ?? 0}</td>
                  <td className="p-2">{row?.total_minutes ?? 0}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
