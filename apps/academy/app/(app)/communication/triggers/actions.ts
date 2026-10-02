'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type TriggerEventType =
  | 'attendance_absent'
  | 'fee_challan_overdue'
  | 'result_published'
  | 'admission_status_changed'
  | 'custom';

export type TriggerRuleRow = {
  id: string;
  tenant_id: string;
  campus_id: string | null;
  name: string;
  description: string | null;
  event_type: TriggerEventType;
  condition: Record<string, any>;
  template_version_id: string | null;
  template_id: string | null;
  channel: string;
  is_enabled: boolean;
  last_evaluated_at: string | null;
  created_at: string;
  updated_at: string;
  fire_count?: number;
};

export type TriggerFireRow = {
  id: string;
  tenant_id: string;
  rule_id: string;
  rule_name?: string;
  event_type?: string;
  entity_id: string;
  fire_key: string;
  status: 'pending' | 'enqueued' | 'skipped' | 'cancelled';
  enqueued_message_id: string | null;
  skip_reason: string | null;
  metadata: Record<string, any>;
  fired_at: string;
  enqueued_at: string | null;
};

export type TriggerRulesStats = {
  totalRules: number;
  enabledRules: number;
  pendingFires: number;
  enqueuedFires: number;
  cancelledFires: number;
};

export type TriggerRulesData = {
  rules: TriggerRuleRow[];
  fires: TriggerFireRow[];
  stats: TriggerRulesStats;
  tenantId: string | null;
  campusId: string | null;
};

async function resolveTenantAndCampus() {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data: userData } = await client.auth.getUser();
  const userId = userData?.user?.id;

  let tenantId: string | null = null;
  let campusId: string | null = null;

  if (userId) {
    const { data: appUser } = await client
      .from('app_user')
      .select('tenant_id')
      .eq('user_id', userId)
      .maybeSingle();
    tenantId = appUser?.tenant_id || null;
  }

  const { data: campus } = await client
    .from('campus')
    .select('id, tenant_id')
    .limit(1)
    .maybeSingle();

  if (!tenantId && campus?.tenant_id) {
    tenantId = campus.tenant_id;
  }
  campusId = campus?.id || null;

  return { client, tenantId, campusId };
}

export async function getTriggerRulesData(): Promise<TriggerRulesData> {
  const { client, tenantId, campusId } = await resolveTenantAndCampus();

  if (!tenantId) {
    return {
      rules: [],
      fires: [],
      stats: {
        totalRules: 0,
        enabledRules: 0,
        pendingFires: 0,
        enqueuedFires: 0,
        cancelledFires: 0,
      },
      tenantId: null,
      campusId: null,
    };
  }

  // Ensure default trigger rules are seeded
  await client.rpc('seed_default_trigger_rules', {
    p_tenant_id: tenantId,
    p_campus_id: campusId,
  });

  // 1. Fetch trigger rules
  const { data: rulesRaw } = await client
    .from('comm_trigger_rule')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('created_at', { ascending: true });

  const rules: TriggerRuleRow[] = (rulesRaw || []).map((r: any) => ({
    ...r,
    condition: typeof r.condition === 'string' ? JSON.parse(r.condition) : r.condition || {},
  }));

  // 2. Fetch trigger fires
  const { data: firesRaw } = await client
    .from('comm_trigger_fire')
    .select(`
      *,
      comm_trigger_rule (
        name,
        event_type
      )
    `)
    .eq('tenant_id', tenantId)
    .order('fired_at', { ascending: false })
    .limit(100);

  const fires: TriggerFireRow[] = (firesRaw || []).map((f: any) => ({
    ...f,
    rule_name: f.comm_trigger_rule?.name || 'Trigger Rule',
    event_type: f.comm_trigger_rule?.event_type || 'custom',
    metadata: typeof f.metadata === 'string' ? JSON.parse(f.metadata) : f.metadata || {},
  }));

  // 3. Compute stats
  const totalRules = rules.length;
  const enabledRules = rules.filter((r) => r.is_enabled).length;
  const pendingFires = fires.filter((f) => f.status === 'pending').length;
  const enqueuedFires = fires.filter((f) => f.status === 'enqueued').length;
  const cancelledFires = fires.filter((f) => f.status === 'cancelled').length;

  return {
    rules,
    fires,
    stats: {
      totalRules,
      enabledRules,
      pendingFires,
      enqueuedFires,
      cancelledFires,
    },
    tenantId,
    campusId,
  };
}

export async function createTriggerRuleAction(input: {
  name: string;
  description?: string;
  eventType: TriggerEventType;
  condition?: Record<string, any>;
  channel?: string;
  isEnabled?: boolean;
}): Promise<{ ok: boolean; data?: TriggerRulesData; error?: string }> {
  try {
    const { client, tenantId, campusId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    if (!input.name?.trim()) {
      return { ok: false, error: 'Rule name is required' };
    }

    const { error } = await client.from('comm_trigger_rule').insert({
      tenant_id: tenantId,
      campus_id: campusId,
      name: input.name.trim(),
      description: input.description?.trim() || null,
      event_type: input.eventType,
      condition: input.condition || {},
      channel: input.channel || 'sms',
      is_enabled: input.isEnabled !== false,
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/triggers');
    const freshData = await getTriggerRulesData();
    return { ok: true, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Failed to create trigger rule' };
  }
}

export async function toggleTriggerRuleAction(
  ruleId: string,
  isEnabled: boolean
): Promise<{ ok: boolean; data?: TriggerRulesData; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    const { error } = await client
      .from('comm_trigger_rule')
      .update({ is_enabled: isEnabled, updated_at: new Date().toISOString() })
      .eq('id', ruleId)
      .eq('tenant_id', tenantId);

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/triggers');
    const freshData = await getTriggerRulesData();
    return { ok: true, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Failed to toggle rule' };
  }
}

export async function deleteTriggerRuleAction(
  ruleId: string
): Promise<{ ok: boolean; data?: TriggerRulesData; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    const { error } = await client
      .from('comm_trigger_rule')
      .delete()
      .eq('id', ruleId)
      .eq('tenant_id', tenantId);

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/triggers');
    const freshData = await getTriggerRulesData();
    return { ok: true, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Failed to delete rule' };
  }
}

export async function runDateBasedEvaluationAction(
  runDate?: string
): Promise<{ ok: boolean; data?: TriggerRulesData; results?: any[]; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    const targetDate = runDate || new Date().toISOString().slice(0, 10);
    const { data: results, error } = await client.rpc('evaluate_date_based_rules', {
      p_run_date: targetDate,
      p_tenant_id: tenantId,
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/triggers');
    const freshData = await getTriggerRulesData();
    return { ok: true, results: results || [], data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Date-based evaluation failed' };
  }
}

export async function processPendingFiresAction(): Promise<{
  ok: boolean;
  data?: TriggerRulesData;
  processedCount?: number;
  error?: string;
}> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    const { data: processed, error } = await client.rpc('process_pending_trigger_fires', {
      p_tenant_id: tenantId,
      p_limit: 200,
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/triggers');
    const freshData = await getTriggerRulesData();
    return { ok: true, processedCount: (processed || []).length, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Process pending fires failed' };
  }
}
