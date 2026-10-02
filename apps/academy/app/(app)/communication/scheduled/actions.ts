'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type CommPolicy = {
  id: string;
  tenant_id: string;
  quiet_start: string;
  quiet_end: string;
  timezone: string;
  emergency_bypass_role: string;
  created_at: string;
  updated_at: string;
};

export type QuietHoursOverride = {
  id: string;
  tenant_id: string;
  name: string;
  date_range: string;
  start_date: string;
  end_date: string;
  quiet_start: string;
  quiet_end: string;
  created_at: string;
  updated_at: string;
};

export type CampaignStatus = 'draft' | 'scheduled' | 'deferred_quiet_hours' | 'dispatching' | 'dispatched' | 'cancelled';

export type MessageCampaignRow = {
  id: string;
  tenant_id: string;
  campus_id: string | null;
  title: string;
  segment_id: string | null;
  segment_name?: string | null;
  template_id: string | null;
  channel: string;
  body: string;
  scheduled_at: string;
  timezone: string;
  status: CampaignStatus;
  deferred_until: string | null;
  is_emergency: boolean;
  emergency_bypass_reason: string | null;
  emergency_approved_by: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
};

export type QuietHoursBypassLogRow = {
  id: string;
  tenant_id: string;
  campaign_id: string;
  campaign_title?: string;
  approver_user_id: string;
  approver_name?: string;
  approver_role: string;
  bypass_reason: string;
  scheduled_at: string;
  dispatched_at: string;
  metadata: Record<string, any>;
};

export type ScheduledSendsStats = {
  totalCampaigns: number;
  scheduledCount: number;
  deferredQuietCount: number;
  dispatchedCount: number;
  emergencyBypassCount: number;
  activeOverridesCount: number;
  isCurrentlyQuiet: boolean;
  currentWindowSummary: string;
};

export type ScheduledSendsData = {
  policy: CommPolicy;
  overrides: QuietHoursOverride[];
  campaigns: MessageCampaignRow[];
  bypassLogs: QuietHoursBypassLogRow[];
  segments: { id: string; name: string; segment_type: string }[];
  stats: ScheduledSendsStats;
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
  let userRole = 'principal';

  if (userId) {
    const { data: appUser } = await client
      .from('app_user')
      .select('tenant_id, app_role')
      .eq('user_id', userId)
      .maybeSingle();
    tenantId = appUser?.tenant_id || null;
    userRole = appUser?.app_role || 'principal';
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

  return { client, userId, userRole, tenantId, campusId };
}

export async function getScheduledSendsData(): Promise<ScheduledSendsData> {
  const { client, tenantId, campusId } = await resolveTenantAndCampus();

  if (!tenantId) {
    return {
      policy: {
        id: '',
        tenant_id: '',
        quiet_start: '21:00:00',
        quiet_end: '08:00:00',
        timezone: 'Asia/Karachi',
        emergency_bypass_role: 'principal',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      },
      overrides: [],
      campaigns: [],
      bypassLogs: [],
      segments: [],
      stats: {
        totalCampaigns: 0,
        scheduledCount: 0,
        deferredQuietCount: 0,
        dispatchedCount: 0,
        emergencyBypassCount: 0,
        activeOverridesCount: 0,
        isCurrentlyQuiet: false,
        currentWindowSummary: '21:00 – 08:00 PKT',
      },
      tenantId: null,
      campusId: null,
    };
  }

  // Ensure default communication policy is seeded
  await client.rpc('seed_default_comm_policy', { p_tenant_id: tenantId });

  // 1. Fetch communication policy
  const { data: policyRow } = await client
    .from('tenant_comm_policy')
    .select('*')
    .eq('tenant_id', tenantId)
    .maybeSingle();

  const policy: CommPolicy = policyRow || {
    id: '',
    tenant_id: tenantId,
    quiet_start: '21:00:00',
    quiet_end: '08:00:00',
    timezone: 'Asia/Karachi',
    emergency_bypass_role: 'principal',
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };

  // 2. Fetch overrides
  const { data: overridesRaw } = await client
    .from('comm_quiet_hours_override')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('created_at', { ascending: false });

  const overrides: QuietHoursOverride[] = (overridesRaw || []).map((o: any) => {
    // date_range is like [2026-10-01,2026-10-31]
    const cleaned = (o.date_range || '').replace(/[\[\]\(\)]/g, '');
    const [start_date = '', end_date = ''] = cleaned.split(',');
    return {
      ...o,
      start_date,
      end_date,
    };
  });

  // 3. Fetch audience segments for dropdown
  const { data: segmentsRaw } = await client
    .from('message_segment')
    .select('id, name, segment_type')
    .eq('tenant_id', tenantId)
    .eq('is_active', true)
    .order('name');

  const segments = (segmentsRaw || []).map((s: any) => ({
    id: s.id,
    name: s.name,
    segment_type: s.segment_type,
  }));

  // 4. Fetch campaigns
  const { data: campaignsRaw } = await client
    .from('message_campaign')
    .select(`
      *,
      message_segment (
        name
      )
    `)
    .eq('tenant_id', tenantId)
    .order('created_at', { ascending: false });

  const campaigns: MessageCampaignRow[] = (campaignsRaw || []).map((c: any) => ({
    ...c,
    segment_name: c.message_segment?.name || null,
  }));

  // 5. Fetch bypass logs
  const { data: logsRaw } = await client
    .from('quiet_hours_bypass_log')
    .select(`
      *,
      message_campaign (
        title
      )
    `)
    .eq('tenant_id', tenantId)
    .order('dispatched_at', { ascending: false });

  const bypassLogs: QuietHoursBypassLogRow[] = (logsRaw || []).map((l: any) => ({
    ...l,
    campaign_title: l.message_campaign?.title || 'Emergency Campaign',
  }));

  // 6. Check quiet status right now
  let isCurrentlyQuiet = false;
  try {
    const { data: quietNow } = await client.rpc('is_quiet_now', {
      p_tenant_id: tenantId,
      p_at: new Date().toISOString(),
    });
    isCurrentlyQuiet = Boolean(quietNow);
  } catch {
    // fallback
  }

  // 7. Compute stats
  const scheduledCount = campaigns.filter((c) => c.status === 'scheduled').length;
  const deferredQuietCount = campaigns.filter((c) => c.status === 'deferred_quiet_hours').length;
  const dispatchedCount = campaigns.filter((c) => ['dispatching', 'dispatched'].includes(c.status)).length;
  const emergencyBypassCount = bypassLogs.length;

  return {
    policy,
    overrides,
    campaigns,
    bypassLogs,
    segments,
    stats: {
      totalCampaigns: campaigns.length,
      scheduledCount,
      deferredQuietCount,
      dispatchedCount,
      emergencyBypassCount,
      activeOverridesCount: overrides.length,
      isCurrentlyQuiet,
      currentWindowSummary: `${policy.quiet_start.slice(0, 5)} – ${policy.quiet_end.slice(0, 5)} PKT`,
    },
    tenantId,
    campusId,
  };
}

export async function scheduleCampaignAction(input: {
  title: string;
  segmentId?: string | null;
  channel: string;
  body: string;
  scheduledAt: string; // ISO string or local PKT string
  isEmergency?: boolean;
  emergencyBypassReason?: string | null;
}): Promise<{ ok: boolean; campaignId?: string; data?: ScheduledSendsData; error?: string }> {
  try {
    const { client, tenantId, campusId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    if (!input.title?.trim()) {
      return { ok: false, error: 'Campaign title is required' };
    }
    if (!input.body?.trim()) {
      return { ok: false, error: 'Message body cannot be empty' };
    }
    if (!input.scheduledAt) {
      return { ok: false, error: 'Scheduled date and time is required' };
    }

    // Call Postgres RPC public.schedule_campaign
    const { data: campaignId, error: rpcError } = await client.rpc('schedule_campaign', {
      p_title: input.title.trim(),
      p_segment_id: input.segmentId || null,
      p_template_id: null,
      p_channel: input.channel || 'sms',
      p_body: input.body.trim(),
      p_scheduled_at: input.scheduledAt,
      p_timezone: 'Asia/Karachi',
      p_is_emergency: Boolean(input.isEmergency),
      p_emergency_bypass_reason: input.isEmergency ? input.emergencyBypassReason?.trim() || null : null,
      p_campus_id: campusId,
    });

    if (rpcError) {
      if (rpcError.message.includes('SCHEDULED_TIME_IN_PAST')) {
        return {
          ok: false,
          error: 'Validation Error: Scheduled time cannot be in the past. Please select a future time.',
        };
      }
      if (rpcError.message.includes('EMERGENCY_REASON_REQUIRED')) {
        return {
          ok: false,
          error: 'Emergency Bypass Error: A documented reason is required to bypass quiet hours compliance.',
        };
      }
      return { ok: false, error: rpcError.message };
    }

    revalidatePath('/communication/scheduled');
    const freshData = await getScheduledSendsData();
    return { ok: true, campaignId, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Failed to schedule campaign' };
  }
}

export async function runDispatcherEvaluationAction(): Promise<{
  ok: boolean;
  evaluations?: any[];
  data?: ScheduledSendsData;
  error?: string;
}> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    const { data: evaluations, error } = await client.rpc('evaluate_scheduled_campaigns', {
      p_tenant_id: tenantId,
      p_as_of: new Date().toISOString(),
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/scheduled');
    const freshData = await getScheduledSendsData();
    return { ok: true, evaluations: evaluations || [], data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Dispatcher evaluation failed' };
  }
}

export async function updateCommPolicyAction(input: {
  quietStart: string;
  quietEnd: string;
}): Promise<{ ok: boolean; data?: ScheduledSendsData; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    const { error } = await client
      .from('tenant_comm_policy')
      .upsert({
        tenant_id: tenantId,
        quiet_start: input.quietStart,
        quiet_end: input.quietEnd,
        timezone: 'Asia/Karachi',
        emergency_bypass_role: 'principal',
        updated_at: new Date().toISOString(),
      }, { onConflict: 'tenant_id' });

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/scheduled');
    const freshData = await getScheduledSendsData();
    return { ok: true, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Failed to update quiet hours policy' };
  }
}

export async function createSeasonalOverrideAction(input: {
  name: string;
  startDate: string;
  endDate: string;
  quietStart: string;
  quietEnd: string;
}): Promise<{ ok: boolean; data?: ScheduledSendsData; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    if (!input.name?.trim()) {
      return { ok: false, error: 'Override name is required (e.g. Ramadan Quiet Hours)' };
    }
    if (!input.startDate || !input.endDate) {
      return { ok: false, error: 'Start date and end date are required' };
    }

    const daterangeStr = `[${input.startDate},${input.endDate}]`;

    const { error } = await client
      .from('comm_quiet_hours_override')
      .insert({
        tenant_id: tenantId,
        name: input.name.trim(),
        date_range: daterangeStr,
        quiet_start: input.quietStart,
        quiet_end: input.quietEnd,
      });

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/scheduled');
    const freshData = await getScheduledSendsData();
    return { ok: true, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Failed to create seasonal override' };
  }
}

export async function deleteSeasonalOverrideAction(overrideId: string): Promise<{ ok: boolean; data?: ScheduledSendsData; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    const { error } = await client
      .from('comm_quiet_hours_override')
      .delete()
      .eq('id', overrideId)
      .eq('tenant_id', tenantId);

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/scheduled');
    const freshData = await getScheduledSendsData();
    return { ok: true, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Failed to delete override' };
  }
}

export async function cancelCampaignAction(campaignId: string): Promise<{ ok: boolean; data?: ScheduledSendsData; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { ok: false, error: 'Tenant context required' };
    }

    const { error } = await client
      .from('message_campaign')
      .update({ status: 'cancelled', updated_at: new Date().toISOString() })
      .eq('id', campaignId)
      .eq('tenant_id', tenantId);

    if (error) {
      return { ok: false, error: error.message };
    }

    revalidatePath('/communication/scheduled');
    const freshData = await getScheduledSendsData();
    return { ok: true, data: freshData };
  } catch (err: any) {
    return { ok: false, error: err?.message || 'Failed to cancel campaign' };
  }
}
