'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { triggerTimetableExport } from './actions';
import type { TimetableExportLayout } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type VersionOption = {
  id: string;
  name: string;
  version_no: number;
  status: string;
  shift: string;
  campus_id: string;
  campus: { code: string; name: string } | null;
};

export type StaffOption = { user_id: string; full_name: string };

export type ExportJobRow = {
  id: string;
  layout: TimetableExportLayout;
  status: 'queued' | 'running' | 'completed' | 'failed';
  page_count: number | null;
  missing_glyph_count: number | null;
  font_family: string | null;
  download_url: string | null;
  download_expires_at: string | null;
  requested_at: string;
  error: string | null;
};

const LAYOUT_LABEL: Record<TimetableExportLayout, string> = {
  section: 'Per section (A4 portrait)',
  teacher: 'Per teacher (A4 portrait)',
  master: 'Master grid (A3 landscape)',
};

const STATUS_LABEL: Record<ExportJobRow['status'], string> = {
  queued: 'Queued',
  running: 'Running',
  completed: 'Completed',
  failed: 'Failed',
};

const ALL_STAFF = '__all__';

export function TimetableExportView({
  layouts,
  versions,
  staff,
  jobs: initialJobs,
  canChooseStaff,
}: {
  layouts: TimetableExportLayout[];
  versions: VersionOption[];
  staff: StaffOption[];
  jobs: ExportJobRow[];
  canChooseStaff: boolean;
}) {
  const [pending, startTransition] = useTransition();
  const [layout, setLayout] = useState<TimetableExportLayout>(layouts[0]!);
  const [versionId, setVersionId] = useState(versions[0]?.id ?? '');
  const [staffId, setStaffId] = useState(ALL_STAFF);
  const [latest, setLatest] = useState<{ pageCount: number; missingGlyphCount: number; downloadUrl: string } | null>(null);
  const [jobs, setJobs] = useState(initialJobs);

  const onGenerate = () => {
    if (!versionId) {
      toast.error('Choose a timetable version.');
      return;
    }
    const fd = new FormData();
    fd.set('versionId', versionId);
    fd.set('layout', layout);
    if (canChooseStaff && layout === 'teacher' && staffId !== ALL_STAFF) fd.set('staffId', staffId);

    startTransition(async () => {
      const result = await triggerTimetableExport({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      const pageCount = result.pageCount ?? 0;
      const missingGlyphCount = result.missingGlyphCount ?? 0;
      toast.success(`Export ready — ${pageCount} page${pageCount === 1 ? '' : 's'}.`);
      setLatest({ pageCount, missingGlyphCount, downloadUrl: result.downloadUrl! });
      setJobs((prev) => [
        {
          id: result.jobId!,
          layout,
          status: 'completed',
          page_count: pageCount,
          missing_glyph_count: missingGlyphCount,
          font_family: null,
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
            <Label htmlFor="export-version">Timetable version</Label>
            <Select value={versionId} onValueChange={setVersionId}>
              <SelectTrigger id="export-version" className="min-w-72" data-testid="timetable-export-version-trigger">
                <SelectValue placeholder="Choose a version" />
              </SelectTrigger>
              <SelectContent>
                {versions.map((v) => (
                  <SelectItem key={v.id} value={v.id} data-testid={`timetable-export-version-${v.id}`}>
                    v{v.version_no} · {v.name} · {v.status} · {v.campus?.code ?? ''}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1">
            <Label htmlFor="export-layout">Layout</Label>
            <Select value={layout} onValueChange={(v) => setLayout(v as TimetableExportLayout)}>
              <SelectTrigger id="export-layout" className="min-w-64" data-testid="timetable-export-layout-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {layouts.map((l) => (
                  <SelectItem key={l} value={l} data-testid={`timetable-export-layout-${l}`}>
                    {LAYOUT_LABEL[l]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {canChooseStaff && layout === 'teacher' && (
            <div className="space-y-1">
              <Label htmlFor="export-staff">Teacher</Label>
              <Select value={staffId} onValueChange={setStaffId}>
                <SelectTrigger id="export-staff" className="min-w-56" data-testid="timetable-export-staff-trigger">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={ALL_STAFF} data-testid="timetable-export-staff-all">
                    Every teacher
                  </SelectItem>
                  {staff.map((s) => (
                    <SelectItem key={s.user_id} value={s.user_id} data-testid={`timetable-export-staff-${s.user_id}`}>
                      {s.full_name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}
        </div>

        {versions.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="timetable-export-no-versions">
            No timetable versions are visible for the current session.
          </p>
        ) : (
          <Button type="button" disabled={pending} onClick={onGenerate} data-testid="timetable-export-run-button">
            {pending ? 'Rendering…' : 'Generate PDF'}
          </Button>
        )}

        {latest && (
          <p className="text-sm" data-testid="timetable-export-latest-result">
            {latest.pageCount} page{latest.pageCount === 1 ? '' : 's'} · {latest.missingGlyphCount} missing glyph
            {latest.missingGlyphCount === 1 ? '' : 's'} —{' '}
            <a href={latest.downloadUrl} className="underline" data-testid="timetable-export-download-link" download>
              Download
            </a>
          </p>
        )}
      </div>

      <div className="space-y-2">
        <h2 className="text-lg font-medium">Recent exports</h2>
        {jobs.length === 0 ? (
          <p className="text-sm text-muted-foreground">No timetable exports have been requested yet.</p>
        ) : (
          jobs.map((job) => (
            <Card key={job.id} data-testid={`timetable-export-job-${job.id}`}>
              <CardContent className="flex items-center justify-between gap-4 p-4 text-sm">
                <div>
                  <p className="font-medium">{LAYOUT_LABEL[job.layout]}</p>
                  <p className="text-xs text-muted-foreground">
                    Requested {new Date(job.requested_at).toLocaleString()} — {STATUS_LABEL[job.status]}
                    {job.status === 'completed' && job.page_count !== null ? ` (${job.page_count} pages)` : ''}
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
