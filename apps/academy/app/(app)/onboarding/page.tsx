import { supabaseServer } from '@/lib/supabase/server';
import { OnboardingView, type StepRow, type PresetOption } from './onboarding-view';
import { STEP_META } from './step-meta';

export default async function OnboardingPage() {
  const supabase = await supabaseServer();

  const [{ data: tenant }, { data: progress }, { data: presets }, { data: campuses }, { data: sessions }] = await Promise.all([
    supabase.from('tenant').select('id').single(),
    supabase.from('onboarding_progress').select('step_key, status, completed_at'),
    supabase.from('class_structure_preset').select('code, label').order('code'),
    supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1),
    supabase.from('academic_session').select('id').eq('is_current', true).limit(1),
  ]);

  const byKey = new Map((progress ?? []).map((r) => [r.step_key, r]));
  const steps: StepRow[] = STEP_META.map((meta) => {
    const row = byKey.get(meta.key);
    return { key: meta.key, status: row?.status ?? 'pending', completedAt: row?.completed_at ?? null };
  });

  const presetOptions: PresetOption[] = (presets ?? []).map((p) => ({ code: p.code, label: p.label }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Setup checklist</h1>
        <p className="text-sm text-muted-foreground">
          FR-A03 — a resumable 7-step checklist from an empty tenant to your first enrolled student. Nothing here blocks
          you from using the rest of the app.
        </p>
      </div>
      {tenant && (
        <OnboardingView
          steps={steps}
          presets={presetOptions}
          tenantId={tenant.id}
          campusId={campuses?.[0]?.id ?? null}
          sessionId={sessions?.[0]?.id ?? null}
        />
      )}
    </div>
  );
}
