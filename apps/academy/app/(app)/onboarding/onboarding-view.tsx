'use client';

import Link from 'next/link';
import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { markOnboardingStep, applyClassPreset } from './actions';
import { STEP_META, type OnboardingStepKey } from './step-meta';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type StepRow = { key: OnboardingStepKey; status: 'pending' | 'skipped' | 'done'; completedAt: string | null };
export type PresetOption = { code: string; label: string };

const STATUS_LABEL: Record<StepRow['status'], string> = { pending: 'Not started', skipped: 'Skipped', done: 'Done' };

function ClassStructureControls({
  tenantId,
  campusId,
  sessionId,
  presets,
}: {
  tenantId: string;
  campusId: string;
  sessionId: string;
  presets: PresetOption[];
}) {
  const [presetCode, setPresetCode] = useState(presets[0]?.code ?? '');
  const [pending, startTransition] = useTransition();

  const onApply = () => {
    if (!presetCode) return;
    startTransition(async () => {
      const result = await applyClassPreset(tenantId, campusId, sessionId, presetCode, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Class structure applied.');
    });
  };

  return (
    <div className="flex flex-wrap items-center gap-2">
      <Select value={presetCode} onValueChange={setPresetCode}>
        <SelectTrigger data-testid="onboarding-preset-trigger" className="w-64">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {presets.map((p) => (
            <SelectItem key={p.code} value={p.code}>
              {p.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Button type="button" size="sm" disabled={pending || !presetCode} onClick={onApply} data-testid="onboarding-apply-preset">
        {pending ? 'Applying…' : 'Apply preset'}
      </Button>
    </div>
  );
}

function StepActions({ stepKey }: { stepKey: OnboardingStepKey }) {
  const [pending, startTransition] = useTransition();

  const mark = (status: 'done' | 'skipped') => {
    startTransition(async () => {
      const result = await markOnboardingStep(stepKey, status, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success(status === 'done' ? 'Marked done.' : 'Skipped.');
    });
  };

  return (
    <div className="flex gap-2">
      <Button type="button" size="sm" disabled={pending} onClick={() => mark('done')} data-testid={`onboarding-done-${stepKey}`}>
        Mark done
      </Button>
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => mark('skipped')} data-testid={`onboarding-skip-${stepKey}`}>
        Skip
      </Button>
    </div>
  );
}

export function OnboardingView({
  steps,
  presets,
  tenantId,
  campusId,
  sessionId,
}: {
  steps: StepRow[];
  presets: PresetOption[];
  tenantId: string;
  campusId: string | null;
  sessionId: string | null;
}) {
  const stepsResolved = steps.filter((s) => s.status !== 'pending').length;
  const firstPendingKey = steps.find((s) => s.status === 'pending')?.key ?? null;
  const complete = stepsResolved === steps.length;

  return (
    <div className="space-y-4">
      <p className="text-sm font-medium" data-testid="onboarding-progress">
        {stepsResolved}/{steps.length} complete
      </p>
      {complete && (
        <Card className="border-green-600">
          <CardContent className="p-4 text-sm">
            Setup is complete. You can still revisit any step below at any time.
          </CardContent>
        </Card>
      )}
      <div className="space-y-3">
        {STEP_META.map((meta) => {
          const row = steps.find((s) => s.key === meta.key)!;
          const isCurrent = meta.key === firstPendingKey;
          return (
            <Card key={meta.key} data-testid={`onboarding-step-${meta.key}`} className={isCurrent ? 'border-primary' : undefined}>
              <CardContent className="space-y-3 p-4">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="font-medium">{meta.title}</p>
                    <p className="text-sm text-muted-foreground">{meta.description}</p>
                  </div>
                  <span className="rounded-full border px-2 py-0.5 text-xs text-muted-foreground" data-testid={`onboarding-status-${meta.key}`}>
                    {STATUS_LABEL[row.status]}
                  </span>
                </div>
                {meta.href && (
                  <Link href={meta.href} className="text-sm text-primary underline">
                    Go to {meta.title}
                  </Link>
                )}
                {meta.key === 'class_structure' && campusId && sessionId && (
                  <ClassStructureControls tenantId={tenantId} campusId={campusId} sessionId={sessionId} presets={presets} />
                )}
                <StepActions stepKey={meta.key} />
              </CardContent>
            </Card>
          );
        })}
      </div>
    </div>
  );
}
