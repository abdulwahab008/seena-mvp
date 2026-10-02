import { supabaseServer } from '@/lib/supabase/server';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { FeatureFlagsView, type FlagRow, type PlanOption } from './feature-flags-view';

export default async function FeatureFlagsPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase
    .from('app_user')
    .select('app_role, tenant_id')
    .eq('user_id', user!.id)
    .single();

  const isSuperAdmin = appUser?.app_role === 'super_admin';

  const [{ data: catalogue }, { data: resolved }, { data: plans }, { data: subscription }, { data: overrides }] =
    await Promise.all([
      supabase.from('feature_flag').select('code, label, description, is_beta').order('code'),
      supabase.rpc('resolved_features'),
      supabase.from('plan').select('code, name').order('rank'),
      supabase
        .from('tenant_subscription')
        .select('plan_code')
        .is('valid_to', null)
        .eq('tenant_id', appUser!.tenant_id)
        .maybeSingle(),
      supabase.from('tenant_feature_override').select('feature_code, enabled').eq('tenant_id', appUser!.tenant_id),
    ]);

  const resolvedMap = (resolved ?? {}) as Record<string, boolean>;
  const overrideMap = new Map(
    (overrides ?? []).map((o) => [o.feature_code as string, o.enabled as boolean] as const),
  );

  const rows: FlagRow[] = (catalogue ?? []).map((f) => ({
    code: f.code as string,
    label: f.label as string,
    description: (f.description as string | null) ?? '',
    isBeta: f.is_beta as boolean,
    enabled: resolvedMap[f.code as string] === true,
    override: overrideMap.has(f.code as string) ? (overrideMap.get(f.code as string) as boolean) : null,
  }));

  return (
    <div className="space-y-6">
      <PageHeader
        title="Modules"
        description={
          isSuperAdmin
            ? 'Switch a module on or off for this school. Turning one off hides it and refuses writes at the database — it never deletes anything, so switching it back on restores everything as it was.'
            : 'What this school’s plan includes. Only the platform team can change these.'
        }
        actions={
          <Badge variant={isSuperAdmin ? 'default' : 'outline'} data-testid="plan-badge">
            {plans?.find((p) => p.code === subscription?.plan_code)?.name ?? 'No plan'}
          </Badge>
        }
      />
      <FeatureFlagsView
        tenantId={appUser!.tenant_id}
        rows={rows}
        plans={(plans ?? []) as PlanOption[]}
        planCode={(subscription?.plan_code as string | undefined) ?? ''}
        canEdit={isSuperAdmin}
      />
    </div>
  );
}
