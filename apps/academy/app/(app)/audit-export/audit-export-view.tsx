'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { triggerAuditExport } from './actions';
import { AUDIT_EXPORT_ENTITIES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DatePicker } from '@/components/ui/date-picker';
import { ALL_CAMPUSES_VALUE, buildCampusFilterOptions, type CampusOption } from '@/lib/campus-scope';

export type AuditExportJobRow = {
  id: string;
  from_date: string;
  to_date: string;
  table_names: string[];
  campus_id: string | null;
  status: 'queued' | 'running' | 'completed' | 'failed';
  row_count: number | null;
  download_url: string | null;
  download_expires_at: string | null;
  requested_at: string;
  error: string | null;
};

const STATUS_LABEL: Record<AuditExportJobRow['status'], string> = {
  queued: 'Queued',
  running: 'Running',
  completed: 'Completed',
  failed: 'Failed',
};

// Radix's Select.Item rejects an empty-string value — '' is the
// campus-scope module's own "All campuses" sentinel, mapped the same way
// CollectionReportView already does.
const UI_ALL_SENTINEL = '__all__';
const toUiValue = (v: string) => (v === ALL_CAMPUSES_VALUE ? UI_ALL_SENTINEL : v);
const fromUiValue = (v: string) => (v === UI_ALL_SENTINEL ? ALL_CAMPUSES_VALUE : v);

export function AuditExportView({ campuses, jobs: initialJobs }: { campuses: CampusOption[]; jobs: AuditExportJobRow[] }) {
  const [pending, startTransition] = useTransition();
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [selectedEntities, setSelectedEntities] = useState<string[]>([]);
  const [campusId, setCampusId] = useState(ALL_CAMPUSES_VALUE);
  const [latestResult, setLatestResult] = useState<{ rowCount: number; downloadUrl: string } | null>(null);
  const [jobs, setJobs] = useState(initialJobs);

  const campusOptions = buildCampusFilterOptions(campuses);
  const campusName = (id: string | null) => campuses.find((c) => c.id === id)?.name ?? null;

  const toggleEntity = (entity: string) => {
    setSelectedEntities((prev) => (prev.includes(entity) ? prev.filter((e) => e !== entity) : [...prev, entity]));
  };

  const onGenerate = () => {
    if (!from || !to) {
      toast.error('Choose a date range.');
      return;
    }
    if (selectedEntities.length === 0) {
      toast.error('Choose at least one entity.');
      return;
    }
    const fd = new FormData();
    fd.set('from', from);
    fd.set('to', to);
    fd.set('campusId', campusId);
    selectedEntities.forEach((e) => fd.append('tableNames', e));

    startTransition(async () => {
      const result = await triggerAuditExport({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      const rowCount = result.rowCount ?? 0;
      toast.success(`Export ready — ${rowCount} row${rowCount === 1 ? '' : 's'}.`);
      setLatestResult({ rowCount, downloadUrl: result.downloadUrl! });
      setJobs((prev) => [
        {
          id: result.jobId!,
          from_date: from,
          to_date: to,
          table_names: selectedEntities,
          campus_id: campusId || null,
          status: 'completed',
          row_count: rowCount,
          download_url: result.downloadUrl!,
          download_expires_at: null,
          requested_at: new Date().toISOString(),
          error: null,
        },
        ...prev,
      ]);
    });
  };

  return (
    <div className="space-y-6">
      <div className="space-y-4 rounded-lg border p-4">
        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <Label htmlFor="export-from">From</Label>
            <DatePicker id="export-from" data-testid="export-from-input" value={from} onChange={setFrom} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="export-to">To</Label>
            <DatePicker id="export-to" data-testid="export-to-input" value={to} onChange={setTo} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="export-campus">Campus</Label>
            <Select value={toUiValue(campusId)} onValueChange={(v) => setCampusId(fromUiValue(v))}>
              <SelectTrigger id="export-campus" data-testid="export-campus-trigger">
                <SelectValue placeholder="All campuses" />
              </SelectTrigger>
              <SelectContent>
                {campusOptions.map((o) => (
                  <SelectItem
                    key={o.value || 'all'}
                    value={toUiValue(o.value)}
                    data-testid={o.value === ALL_CAMPUSES_VALUE ? 'export-campus-option-all' : `export-campus-option-${o.value}`}
                  >
                    {o.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>

        <div className="space-y-1">
          <Label>Entities</Label>
          <div className="flex flex-wrap gap-3">
            {AUDIT_EXPORT_ENTITIES.map((entity) => (
              <label key={entity} className="flex items-center gap-2 text-sm" data-testid={`export-entity-${entity}`}>
                <input type="checkbox" checked={selectedEntities.includes(entity)} onChange={() => toggleEntity(entity)} />
                {entity.replace(/_/g, ' ')}
              </label>
            ))}
          </div>
        </div>

        <Button type="button" disabled={pending} onClick={onGenerate} data-testid="export-run-button">
          {pending ? 'Generating…' : 'Generate export'}
        </Button>

        {latestResult && (
          <p className="text-sm" data-testid="export-latest-result">
            {latestResult.rowCount} row{latestResult.rowCount === 1 ? '' : 's'} —{' '}
            <a href={latestResult.downloadUrl} className="underline" data-testid="export-download-link" download>
              Download
            </a>
          </p>
        )}
      </div>

      <div className="space-y-2">
        <h2 className="text-lg font-medium">Recent exports</h2>
        {jobs.length === 0 ? (
          <p className="text-sm text-muted-foreground">No exports have been requested yet.</p>
        ) : (
          jobs.map((job) => (
            <Card key={job.id} data-testid={`export-job-${job.id}`}>
              <CardContent className="flex items-center justify-between gap-4 p-4 text-sm">
                <div>
                  <p className="font-medium">
                    {job.from_date} → {job.to_date} · {job.table_names.join(', ')}
                    {campusName(job.campus_id) ? ` · ${campusName(job.campus_id)}` : ' · All campuses'}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    Requested {new Date(job.requested_at).toLocaleString()} — {STATUS_LABEL[job.status]}
                    {job.status === 'completed' && job.row_count !== null ? ` (${job.row_count} rows)` : ''}
                    {job.status === 'failed' && job.error ? `: ${job.error}` : ''}
                  </p>
                </div>
                {job.status === 'completed' && job.download_url && (
                  <a href={job.download_url} className="shrink-0 text-sm underline" download>
                    Download
                  </a>
                )}
              </CardContent>
            </Card>
          ))
        )}
      </div>
    </div>
  );
}
