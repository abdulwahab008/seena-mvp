'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type WaTemplateStatus = 'APPROVED' | 'PENDING' | 'REJECTED' | 'PAUSED';
export type WaTemplateCategory = 'UTILITY' | 'MARKETING' | 'AUTHENTICATION' | 'SERVICE';

export type WaTemplateRow = {
  id: string;
  tenant_id: string;
  meta_template_name: string;
  category: WaTemplateCategory;
  status: WaTemplateStatus;
  language: string;
  body_text: string;
  rejection_reason: string | null;
  last_synced_at: string;
  created_at: string;
  updated_at: string;
};

export type WaSessionWindowRow = {
  id: string;
  tenant_id: string;
  msisdn: string;
  window_opened_at: string;
  window_expires_at: string;
  last_inbound_id: string | null;
  created_at: string;
  updated_at: string;
  is_active?: boolean;
};

export type WaInboundMessageRow = {
  id: string;
  tenant_id: string;
  msisdn: string;
  wam_id: string | null;
  message_type: string;
  body: string | null;
  received_at: string;
};

export type WaComplianceAlertRow = {
  id: string;
  tenant_id: string;
  template_id: string | null;
  alert_type: string;
  title: string;
  message: string;
  is_resolved: boolean;
  created_at: string;
};

export type WhatsAppComplianceStats = {
  totalTemplates: number;
  approvedTemplates: number;
  pendingTemplates: number;
  rejectedTemplates: number;
  activeSessionWindows: number;
  totalSessionWindows: number;
  unresolvedAlerts: number;
};

export type WhatsAppComplianceData = {
  templates: WaTemplateRow[];
  sessionWindows: WaSessionWindowRow[];
  complianceAlerts: WaComplianceAlertRow[];
  recentInbound: WaInboundMessageRow[];
  stats: WhatsAppComplianceStats;
};

/**
 * Resolves the tenant_id and campus_id for the current user session.
 */
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

/**
 * Fetch all WhatsApp compliance data including registered Meta templates,
 * active 24-hour customer service session windows, alerts, and inbound messages.
 */
export async function getWhatsAppComplianceData(): Promise<WhatsAppComplianceData> {
  const { client, tenantId } = await resolveTenantAndCampus();

  if (!tenantId) {
    return {
      templates: [],
      sessionWindows: [],
      complianceAlerts: [],
      recentInbound: [],
      stats: {
        totalTemplates: 0,
        approvedTemplates: 0,
        pendingTemplates: 0,
        rejectedTemplates: 0,
        activeSessionWindows: 0,
        totalSessionWindows: 0,
        unresolvedAlerts: 0,
      },
    };
  }

  // 1. Fetch Meta Templates
  const { data: templates } = await client
    .from('wa_template')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('created_at', { ascending: false });

  // 2. Fetch Session Windows
  const { data: sessionWindows } = await client
    .from('wa_session_window')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('window_expires_at', { ascending: false });

  // 3. Fetch Compliance Alerts
  const { data: complianceAlerts } = await client
    .from('wa_compliance_alert')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('created_at', { ascending: false });

  // 4. Fetch Recent Inbound Messages
  const { data: recentInbound } = await client
    .from('wa_inbound_message')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('received_at', { ascending: false })
    .limit(20);

  const now = new Date();
  const rawWindows = (sessionWindows || []) as WaSessionWindowRow[];
  const windowRowsWithStatus = rawWindows.map((w) => ({
    ...w,
    is_active: new Date(w.window_expires_at) > now,
  }));

  const rawTemplates = (templates || []) as WaTemplateRow[];
  const rawAlerts = (complianceAlerts || []) as WaComplianceAlertRow[];

  const stats: WhatsAppComplianceStats = {
    totalTemplates: rawTemplates.length,
    approvedTemplates: rawTemplates.filter((t) => t.status === 'APPROVED').length,
    pendingTemplates: rawTemplates.filter((t) => t.status === 'PENDING').length,
    rejectedTemplates: rawTemplates.filter((t) => t.status === 'REJECTED' || t.status === 'PAUSED').length,
    activeSessionWindows: windowRowsWithStatus.filter((w) => w.is_active).length,
    totalSessionWindows: windowRowsWithStatus.length,
    unresolvedAlerts: rawAlerts.filter((a) => !a.is_resolved).length,
  };

  return {
    templates: rawTemplates,
    sessionWindows: windowRowsWithStatus,
    complianceAlerts: rawAlerts,
    recentInbound: (recentInbound || []) as WaInboundMessageRow[],
    stats,
  };
}

/**
 * Simulate an inbound WhatsApp message from a parent.
 * This triggers `process_wa_inbound_message` to open or renew their 24-hour customer service window.
 */
export async function simulateInboundMessage(input: {
  phone: string;
  body?: string;
}): Promise<{ success: boolean; inboundId?: string; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { success: false, error: 'Tenant context could not be resolved' };
    }

    const cleanPhone = input.phone.trim();
    if (!cleanPhone) {
      return { success: false, error: 'Phone number is required' };
    }

    const wamId = `wam_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
    const { data: inboundId, error } = await client.rpc('process_wa_inbound_message', {
      p_tenant_id: tenantId,
      p_msisdn: cleanPhone,
      p_body: input.body || 'Parent inbound inquiry via WhatsApp',
      p_wam_id: wamId,
      p_received_at: new Date().toISOString(),
    });

    if (error) {
      return { success: false, error: error.message };
    }

    revalidatePath('/communication/whatsapp');
    return { success: true, inboundId };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

/**
 * Register a new WhatsApp Meta template (defaults to PENDING until approved).
 */
export async function registerMetaTemplate(input: {
  name: string;
  category: WaTemplateCategory;
  language?: string;
  bodyText: string;
}): Promise<{ success: boolean; templateId?: string; error?: string }> {
  try {
    const { client, tenantId } = await resolveTenantAndCampus();
    if (!tenantId) {
      return { success: false, error: 'Tenant context could not be resolved' };
    }

    const cleanName = input.name.trim().toLowerCase().replace(/[^a-z0-9_]/g, '_');
    if (!cleanName) {
      return { success: false, error: 'Template name is required' };
    }

    if (!input.bodyText?.trim()) {
      return { success: false, error: 'Body text is required' };
    }

    const { data, error } = await client
      .from('wa_template')
      .insert({
        tenant_id: tenantId,
        meta_template_name: cleanName,
        category: input.category || 'UTILITY',
        status: 'PENDING',
        language: input.language || 'en_US',
        body_text: input.bodyText.trim(),
      })
      .select('id')
      .single();

    if (error) {
      return { success: false, error: error.message };
    }

    revalidatePath('/communication/whatsapp');
    return { success: true, templateId: data.id };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

/**
 * Synchronize template status with Meta.
 * If rejected/paused, auto-pauses scheduled messages and creates Principal compliance alert.
 */
export async function syncMetaTemplateStatus(input: {
  templateId: string;
  newStatus: WaTemplateStatus;
  rejectionReason?: string;
}): Promise<{ success: boolean; error?: string }> {
  try {
    const { client } = await resolveTenantAndCampus();

    const { error } = await client.rpc('sync_wa_template_status', {
      p_template_id: input.templateId,
      p_new_status: input.newStatus,
      p_rejection_reason: input.rejectionReason || null,
    });

    if (error) {
      return { success: false, error: error.message };
    }

    revalidatePath('/communication/whatsapp');
    return { success: true };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

/**
 * Validate and simulate dispatch of a WhatsApp message.
 * Tests 24h window enforcement, template status check, and SMS fallback trigger.
 */
export async function testWhatsAppDispatch(input: {
  phone: string;
  isFreeform: boolean;
  templateId?: string;
  body: string;
}): Promise<{
  success: boolean;
  messageId?: string;
  validationResult?: {
    valid: boolean;
    error?: string;
    mode?: string;
    template?: string;
    escalated_to_attempt?: string;
  };
  attempts?: Array<{
    id: string;
    attempt_number: number;
    channel: string;
    status: string;
    error_code: string | null;
    error_message: string | null;
  }>;
  error?: string;
}> {
  try {
    const { client, tenantId, campusId } = await resolveTenantAndCampus();
    if (!tenantId || !campusId) {
      return { success: false, error: 'Tenant or campus context could not be resolved' };
    }

    const cleanPhone = input.phone.trim();
    if (!cleanPhone) {
      return { success: false, error: 'Recipient phone number is required' };
    }

    // 1. Create message row
    const { data: msg, error: msgError } = await client
      .from('message')
      .insert({
        tenant_id: tenantId,
        campus_id: campusId,
        channel: 'whatsapp',
        recipient_phone: cleanPhone,
        recipient_type: 'guardian',
        sender_id: 'SEENA_WA',
        body: input.body || 'Simulated dispatch test message',
        is_freeform: input.isFreeform,
        wa_template_id: !input.isFreeform && input.templateId ? input.templateId : null,
        status: 'queued',
        idempotency_key: `test-wa-${Date.now()}-${Math.random().toString(36).substring(2, 6)}`,
      })
      .select('id')
      .single();

    if (msgError || !msg) {
      return { success: false, error: msgError?.message || 'Failed to create test message' };
    }

    // 2. Validate dispatch via database RPC
    const { data: valResult, error: valError } = await client.rpc('validate_wa_dispatch', {
      p_message_id: msg.id,
    });

    if (valError) {
      return { success: false, messageId: msg.id, error: valError.message };
    }

    // 3. Fetch any message attempts generated (including fallbacks)
    const { data: attempts } = await client
      .from('message_attempt')
      .select('id, attempt_number, channel, status, error_code, error_message')
      .eq('message_id', msg.id)
      .order('attempt_number', { ascending: true });

    revalidatePath('/communication/whatsapp');
    return {
      success: true,
      messageId: msg.id,
      validationResult: valResult,
      attempts: attempts || [],
    };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

/**
 * Mark a compliance alert as resolved.
 */
export async function resolveComplianceAlert(alertId: string): Promise<{ success: boolean; error?: string }> {
  try {
    const { client } = await resolveTenantAndCampus();

    const { error } = await client
      .from('wa_compliance_alert')
      .update({ is_resolved: true })
      .eq('id', alertId);

    if (error) {
      return { success: false, error: error.message };
    }

    revalidatePath('/communication/whatsapp');
    return { success: true };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}
