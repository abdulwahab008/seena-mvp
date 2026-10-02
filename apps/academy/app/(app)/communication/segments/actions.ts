'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type SegmentType = 'defaulters' | 'absent_today' | 'custom';

export type MessageSegmentRow = {
  id: string;
  tenant_id: string;
  campus_id: string | null;
  name: string;
  description: string | null;
  segment_type: SegmentType;
  definition: Record<string, any>;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

export type SegmentRecipientRow = {
  student_id: string;
  enrolment_id: string;
  guardian_id: string | null;
  student_name: string;
  gr_number: string | null;
  guardian_name: string;
  guardian_phone: string;
  dues_pkr: number | null;
  attendance_status: string | null;
  meta: Record<string, any>;
};

export type AudienceSnapshotRow = {
  id: string;
  campaign_id: string;
  segment_id: string | null;
  student_id: string;
  enrolment_id: string;
  guardian_id: string | null;
  student_name: string;
  gr_number: string | null;
  recipient_name: string;
  recipient_phone: string;
  dues_pkr: number | null;
  attendance_status: string | null;
  segment_metadata: Record<string, any>;
  snapshotted_at: string;
};

export type SegmentStats = {
  totalSegments: number;
  defaulterSegments: number;
  absenteeSegments: number;
  customSegments: number;
  totalSnapshots: number;
};

export type SegmentDataResult = {
  segments: MessageSegmentRow[];
  snapshots: AudienceSnapshotRow[];
  stats: SegmentStats;
  campusCutoffTime: string;
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
    .select('id, tenant_id, attendance_lock_cutoff')
    .limit(1)
    .maybeSingle();

  if (!tenantId && campus?.tenant_id) {
    tenantId = campus.tenant_id;
  }
  campusId = campus?.id || null;

  return { client, tenantId, campusId, attendanceLockCutoff: campus?.attendance_lock_cutoff || '11:00:00' };
}

/**
 * Fetch all dynamic audience segments, recent audience audit snapshots,
 * and campus attendance lock cutoff settings. Auto-seeds defaults if empty.
 */
export async function getSegmentsData(): Promise<SegmentDataResult> {
  const { client, tenantId, campusId, attendanceLockCutoff } = await resolveTenantAndCampus();

  if (!tenantId) {
    return {
      segments: [],
      snapshots: [],
      stats: {
        totalSegments: 0,
        defaulterSegments: 0,
        absenteeSegments: 0,
        customSegments: 0,
        totalSnapshots: 0,
      },
      campusCutoffTime: '11:00:00',
      campusId: null,
    };
  }

  // Fetch segments
  let { data: segments } = await client
    .from('message_segment')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('created_at', { ascending: false });

  // Auto-seed defaults if brand new
  if (!segments || segments.length === 0) {
    if (campusId) {
      await client.rpc('seed_default_segments', {
        p_tenant_id: tenantId,
        p_campus_id: campusId,
      });
      const { data: seeded } = await client
        .from('message_segment')
        .select('*')
        .eq('tenant_id', tenantId)
        .order('created_at', { ascending: false });
      segments = seeded || [];
    }
  }

  // Fetch recent snapshots
  const { data: snapshots } = await client
    .from('message_audience_snapshot')
    .select('*')
    .order('snapshotted_at', { ascending: false })
    .limit(50);

  const segmentList: MessageSegmentRow[] = segments || [];
  const snapshotList: AudienceSnapshotRow[] = snapshots || [];

  const stats: SegmentStats = {
    totalSegments: segmentList.length,
    defaulterSegments: segmentList.filter((s) => s.segment_type === 'defaulters').length,
    absenteeSegments: segmentList.filter((s) => s.segment_type === 'absent_today').length,
    customSegments: segmentList.filter((s) => s.segment_type === 'custom').length,
    totalSnapshots: snapshotList.length,
  };

  return {
    segments: segmentList,
    snapshots: snapshotList,
    stats,
    campusCutoffTime: attendanceLockCutoff,
    campusId,
  };
}

/**
 * Real-time dynamic audience resolution preview with execution timing (sub-2s resolution)
 */
export async function resolveSegmentPreview(
  segmentId: string,
  asOf?: string
): Promise<{
  success: boolean;
  recipients: SegmentRecipientRow[];
  count: number;
  totalDuesPkr: number;
  durationMs: number;
  error?: string;
}> {
  const startTime = Date.now();
  const { client } = await resolveTenantAndCampus();

  try {
    const targetDate = asOf || new Date().toISOString().slice(0, 10);
    const { data, error } = await client.rpc('resolve_segment', {
      p_segment_id: segmentId,
      p_as_of: targetDate,
    });

    const durationMs = Date.now() - startTime;

    if (error) {
      return {
        success: false,
        recipients: [],
        count: 0,
        totalDuesPkr: 0,
        durationMs,
        error: error.message,
      };
    }

    const recipients: SegmentRecipientRow[] = data || [];
    const totalDuesPkr = recipients.reduce((sum, r) => sum + (Number(r.dues_pkr) || 0), 0);

    return {
      success: true,
      recipients,
      count: recipients.length,
      totalDuesPkr,
      durationMs,
    };
  } catch (err: any) {
    const durationMs = Date.now() - startTime;
    return {
      success: false,
      recipients: [],
      count: 0,
      totalDuesPkr: 0,
      durationMs,
      error: err.message || 'Failed to resolve dynamic segment',
    };
  }
}

/**
 * Create a new dynamic audience segment
 */
export async function createSegment(payload: {
  name: string;
  description?: string;
  segmentType: SegmentType;
  definition: Record<string, any>;
}): Promise<{ success: boolean; segment?: MessageSegmentRow; error?: string }> {
  const { client, tenantId, campusId } = await resolveTenantAndCampus();

  if (!tenantId) {
    return { success: false, error: 'Tenant context could not be resolved' };
  }

  const { data, error } = await client
    .from('message_segment')
    .insert({
      tenant_id: tenantId,
      campus_id: campusId,
      name: payload.name.trim(),
      description: payload.description?.trim() || null,
      segment_type: payload.segmentType,
      definition: payload.definition,
      is_active: true,
    })
    .select()
    .single();

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/segments');
  return { success: true, segment: data };
}

/**
 * Update an existing dynamic audience segment
 */
export async function updateSegment(
  id: string,
  payload: {
    name?: string;
    description?: string;
    definition?: Record<string, any>;
    isActive?: boolean;
  }
): Promise<{ success: boolean; error?: string }> {
  const { client, tenantId } = await resolveTenantAndCampus();

  if (!tenantId) {
    return { success: false, error: 'Tenant context could not be resolved' };
  }

  const updateFields: Record<string, any> = {
    updated_at: new Date().toISOString(),
  };

  if (payload.name !== undefined) updateFields.name = payload.name.trim();
  if (payload.description !== undefined) updateFields.description = payload.description.trim();
  if (payload.definition !== undefined) updateFields.definition = payload.definition;
  if (payload.isActive !== undefined) updateFields.is_active = payload.isActive;

  const { error } = await client
    .from('message_segment')
    .update(updateFields)
    .eq('id', id)
    .eq('tenant_id', tenantId);

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/segments');
  return { success: true };
}

/**
 * Delete a dynamic audience segment
 */
export async function deleteSegment(id: string): Promise<{ success: boolean; error?: string }> {
  const { client, tenantId } = await resolveTenantAndCampus();

  if (!tenantId) {
    return { success: false, error: 'Tenant context could not be resolved' };
  }

  const { error } = await client
    .from('message_segment')
    .delete()
    .eq('id', id)
    .eq('tenant_id', tenantId);

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/segments');
  return { success: true };
}

/**
 * Configure per-campus attendance-lock cutoff (e.g. 11:00 PKT)
 */
export async function updateCampusCutoff(cutoffTime: string): Promise<{ success: boolean; error?: string }> {
  const { client, tenantId, campusId } = await resolveTenantAndCampus();

  if (!tenantId || !campusId) {
    return { success: false, error: 'Campus context could not be resolved' };
  }

  const { error } = await client
    .from('campus')
    .update({ attendance_lock_cutoff: cutoffTime })
    .eq('id', campusId)
    .eq('tenant_id', tenantId);

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/segments');
  return { success: true };
}

/**
 * Dispatches a campaign to a dynamic segment and freezes audience in an immutable snapshot.
 * Blocks and raises warning if 0 recipients resolve (FR-M06 AC 3).
 */
export async function dispatchCampaignAudienceSnapshot(
  campaignId: string,
  segmentId: string,
  asOf?: string
): Promise<{ success: boolean; snapshottedCount: number; error?: string }> {
  const { client } = await resolveTenantAndCampus();

  try {
    const targetDate = asOf || new Date().toISOString().slice(0, 10);
    const { data, error } = await client.rpc('snapshot_campaign_audience', {
      p_campaign_id: campaignId,
      p_segment_id: segmentId,
      p_as_of: targetDate,
    });

    if (error) {
      return {
        success: false,
        snapshottedCount: 0,
        error: error.message,
      };
    }

    revalidatePath('/communication/segments');
    return {
      success: true,
      snapshottedCount: Number(data) || 0,
    };
  } catch (err: any) {
    return {
      success: false,
      snapshottedCount: 0,
      error: err.message || 'Failed to dispatch campaign and create audience snapshot',
    };
  }
}
