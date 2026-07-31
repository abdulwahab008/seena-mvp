'use client';

import { useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { previewRollover, applyRollover, type RolloverSummary } from './actions';
import { cloneAcademicStructureSchema, type CloneAcademicStructureInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type CampusOption = { id: string; name: string };
type SessionOption = { id: string; name: string };

export function RolloverForm({ campuses, sessions }: { campuses: CampusOption[]; sessions: SessionOption[] }) {
  const [pending, startTransition] = useTransition();
  const [summary, setSummary] = useState<RolloverSummary | null>(null);
  const [applied, setApplied] = useState(false);
  const sessionName = (id: string) => sessions.find((s) => s.id === id)?.name ?? id;

  const { handleSubmit, control, getValues } = useForm<CloneAcademicStructureInput>({
    resolver: zodResolver(cloneAcademicStructureSchema),
  });

  const run = (dryRun: boolean) =>
    handleSubmit((values) => {
      const fd = new FormData();
      fd.set('campusId', values.campusId);
      fd.set('fromSessionId', values.fromSessionId);
      fd.set('toSessionId', values.toSessionId);

      startTransition(async () => {
        const result = await (dryRun ? previewRollover : applyRollover)({ error: null, summary: null, applied: false }, fd);
        if (result.error) toast.error(result.error);
        else {
          setSummary(result.summary);
          setApplied(result.applied);
          toast.success(dryRun ? 'Preview ready — nothing has been saved yet.' : 'Rollover applied.');
        }
      });
    })();

  return (
    <div className="space-y-4">
      <form onSubmit={(e) => e.preventDefault()} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
        <div className="space-y-1">
          <Label htmlFor="campusId">Campus</Label>
          <Controller
            control={control}
            name="campusId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="rollover-campus-trigger">
                  <SelectValue placeholder="Select a campus" />
                </SelectTrigger>
                <SelectContent>
                  {campuses.map((c) => (
                    <SelectItem key={c.id} value={c.id}>
                      {c.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="fromSessionId">From session</Label>
          <Controller
            control={control}
            name="fromSessionId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="rollover-from-session-trigger">
                  <SelectValue placeholder="Select a session" />
                </SelectTrigger>
                <SelectContent>
                  {sessions.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="toSessionId">To session</Label>
          <Controller
            control={control}
            name="toSessionId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="rollover-to-session-trigger">
                  <SelectValue placeholder="Select a session" />
                </SelectTrigger>
                <SelectContent>
                  {sessions.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="flex items-end gap-2">
          <Button type="button" variant="outline" disabled={pending} onClick={() => run(true)}>
            {pending ? 'Working…' : 'Preview'}
          </Button>
          <Button type="button" disabled={pending} onClick={() => run(false)}>
            {pending ? 'Working…' : 'Confirm rollover'}
          </Button>
        </div>
      </form>

      {summary && (
        <div className="space-y-3 rounded-lg border p-4" data-testid="rollover-summary">
          <p className="text-sm font-medium">
            {applied ? 'Applied' : 'Preview'} — {sessionName(getValues('fromSessionId'))} → {sessionName(getValues('toSessionId'))}
          </p>
          <dl className="grid grid-cols-3 gap-3 text-sm">
            <div>
              <dt className="text-muted-foreground">Sections</dt>
              <dd data-testid="rollover-sections-summary">
                {summary.sections.created} created, {summary.sections.skipped} skipped
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Curriculum maps</dt>
              <dd data-testid="rollover-maps-summary">
                {summary.class_subject_maps.created} created, {summary.class_subject_maps.skipped} skipped
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Allocations</dt>
              <dd data-testid="rollover-allocations-summary">
                {summary.allocations.created} created, {summary.allocations.skipped} skipped
              </dd>
            </div>
          </dl>
          {summary.resigned_staff_allocations.length > 0 && (
            <div>
              <p className="text-sm text-muted-foreground">Allocations referencing resigned staff (cloned unassigned):</p>
              <ul className="list-inside list-disc text-sm" data-testid="rollover-resigned-list">
                {summary.resigned_staff_allocations.map((r, i) => (
                  <li key={i}>
                    {r.staff_name} — {r.section_name}
                    {r.subject_name ? ` (${r.subject_name})` : ' (class teacher)'}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
