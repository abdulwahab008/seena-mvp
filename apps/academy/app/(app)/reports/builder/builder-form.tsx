'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { REPORT_FILTER_OPS, type ReportDefinitionInput } from '@/lib/validation';
import { previewReport, saveReport, type PreviewResult } from './actions';
import { ReportGrid } from './report-grid';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type DatasetOption = { key: string; label: string; columns: { key: string; label: string; type: string }[] };

const OP_LABEL: Record<(typeof REPORT_FILTER_OPS)[number], string> = {
  eq: 'is', neq: 'is not', lt: 'less than', lte: 'at most', gt: 'greater than', gte: 'at least', contains: 'contains', in: 'is one of (comma separated)', is_null: 'is empty', not_null: 'is not empty',
};

type FilterRow = { column: string; op: (typeof REPORT_FILTER_OPS)[number]; value: string };

export function BuilderForm({ datasets }: { datasets: DatasetOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [datasetKey, setDatasetKey] = useState(datasets[0]?.key ?? '');
  const [name, setName] = useState('');
  const [columns, setColumns] = useState<string[]>([]);
  const [groupBy, setGroupBy] = useState<string[]>([]);
  const [filters, setFilters] = useState<FilterRow[]>([]);
  const [isShared, setIsShared] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<PreviewResult | null>(null);

  const dataset = datasets.find((d) => d.key === datasetKey);
  const pick = (list: string[], set: (v: string[]) => void, key: string) => set(list.includes(key) ? list.filter((k) => k !== key) : [...list, key]);
  const definition = (): ReportDefinitionInput => ({ columns, groupBy, filters: filters.map((f) => ({ column: f.column, op: f.op, value: f.value })) });

  const onDatasetChange = (key: string) => {
    setDatasetKey(key);
    setColumns([]);
    setGroupBy([]);
    setFilters([]);
    setPreview(null);
  };

  const runPreview = () =>
    startTransition(async () => {
      setError(null);
      const r = await previewReport(datasetKey, definition());
      setPreview(r);
      if (r.error) setError(r.error);
    });
  const save = () =>
    startTransition(async () => {
      setError(null);
      const r = await saveReport({ name, datasetKey, definition: definition(), isShared });
      if (r.error) setError(r.error);
      else {
        toast.success('Report saved.');
        router.push(`/reports/builder/${r.id}`);
      }
    });

  const select = 'h-9 rounded-md border bg-background px-2 text-sm';
  return (
    <div className="space-y-5" data-testid="report-builder">
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="dataset">Dataset</Label>
          <select id="dataset" className={`${select} w-full`} value={datasetKey} onChange={(e) => onDatasetChange(e.target.value)}>
            {datasets.map((d) => (
              <option key={d.key} value={d.key}>
                {d.label} ({d.columns.length} columns)
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="reportName">Report name</Label>
          <Input id="reportName" value={name} onChange={(e) => setName(e.target.value)} maxLength={120} />
        </div>
      </div>

      <fieldset className="space-y-2" data-testid="column-picker">
        <legend className="text-sm font-medium">Columns</legend>
        <div className="grid gap-1 sm:grid-cols-3">
          {(dataset?.columns ?? []).map((c) => (
            <label key={c.key} className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={columns.includes(c.key)} onChange={() => pick(columns, setColumns, c.key)} />
              {c.label}
            </label>
          ))}
        </div>
      </fieldset>

      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">Filters (all must match)</legend>
        {filters.map((f, i) => (
          <div key={i} className="flex flex-wrap items-center gap-2" data-testid="filter-row">
            <select aria-label="Filter column" className={select} value={f.column} onChange={(e) => setFilters(filters.map((x, j) => (j === i ? { ...x, column: e.target.value } : x)))}>
              {(dataset?.columns ?? []).map((c) => (
                <option key={c.key} value={c.key}>
                  {c.label}
                </option>
              ))}
            </select>
            <select aria-label="Filter operator" className={select} value={f.op} onChange={(e) => setFilters(filters.map((x, j) => (j === i ? { ...x, op: e.target.value as FilterRow['op'] } : x)))}>
              {REPORT_FILTER_OPS.map((op) => (
                <option key={op} value={op}>
                  {OP_LABEL[op]}
                </option>
              ))}
            </select>
            {f.op !== 'is_null' && f.op !== 'not_null' && (
              <Input aria-label="Filter value" className="h-9 w-56" value={f.value} onChange={(e) => setFilters(filters.map((x, j) => (j === i ? { ...x, value: e.target.value } : x)))} />
            )}
            <Button type="button" size="sm" variant="ghost" onClick={() => setFilters(filters.filter((_, j) => j !== i))}>
              Remove
            </Button>
          </div>
        ))}
        <Button type="button" size="sm" variant="outline" disabled={!dataset} onClick={() => setFilters([...filters, { column: dataset!.columns[0]!.key, op: 'eq', value: '' }])} data-testid="add-filter">
          Add filter
        </Button>
      </fieldset>

      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">Group by (optional — shows a row count per group)</legend>
        <div className="grid gap-1 sm:grid-cols-3">
          {(dataset?.columns ?? []).map((c) => (
            <label key={c.key} className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={groupBy.includes(c.key)} onChange={() => pick(groupBy, setGroupBy, c.key)} />
              {c.label}
            </label>
          ))}
        </div>
      </fieldset>

      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={isShared} onChange={(e) => setIsShared(e.target.checked)} />
        Share with colleagues in this school (each person still sees only their own campus&apos;s rows)
      </label>

      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="builder-error">
          {error}
        </p>
      )}
      <div className="flex gap-2">
        <Button type="button" variant="outline" disabled={pending || !dataset} onClick={runPreview} data-testid="preview">
          Preview
        </Button>
        <Button type="button" disabled={pending || !dataset} onClick={save} data-testid="save-report">
          Save report
        </Button>
      </div>

      {preview && !preview.error && preview.columns && preview.rows && (
        <div className="space-y-2" data-testid="preview-result">
          <p className="text-sm text-muted-foreground">
            Showing {preview.rows.length} of {preview.totalRows} rows{preview.elapsedMs !== undefined ? ` · ${Math.round(preview.elapsedMs)} ms` : ''}
          </p>
          {preview.notice && (
            <p role="status" className="rounded-md border border-amber-300 bg-amber-50 p-2 text-sm text-amber-900" data-testid="preview-notice">
              {preview.notice}
            </p>
          )}
          <ReportGrid columns={preview.columns} rows={preview.rows} />
        </div>
      )}
    </div>
  );
}
