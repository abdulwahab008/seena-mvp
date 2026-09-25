'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

const MAX_ATTACHMENT_SIZE_BYTES = 10 * 1024 * 1024; // 10 MB = 10,485,760 bytes
const MAX_ATTACHMENTS_PER_CIRCULAR = 5;

export interface CircularAttachmentInput {
  storage_path: string;
  file_name: string;
  mime_type: string;
  size_bytes: number;
}

export interface CreateCircularPayload {
  title: string;
  body_en?: string;
  body_ur?: string;
  campus_id?: string;
  publish_at?: string;
  expires_at?: string;
  status?: 'draft' | 'published';
  segment_ids?: string[];
  attachments?: CircularAttachmentInput[];
}

export async function fetchCircularsDashboardData() {
  const supabase = await supabaseServer();

  const client = supabase as any;

  const [circularsRes, segmentsRes, campusesRes, statsRes] = await Promise.all([
    client
      .from('circular')
      .select(`
        id,
        tenant_id,
        campus_id,
        title,
        body_en,
        body_ur,
        publish_at,
        expires_at,
        status,
        created_at,
        circular_attachment (
          id,
          storage_path,
          file_name,
          mime_type,
          size_bytes,
          created_at
        ),
        circular_audience (
          id,
          segment_id,
          message_segment (
            id,
            name,
            segment_type
          )
        )
      `)
      .order('publish_at', { ascending: false }),
    client
      .from('message_segment')
      .select('id, name, segment_type, is_active')
      .eq('is_active', true)
      .order('name'),
    client
      .from('campus')
      .select('id, name')
      .order('name'),
    client
      .from('v_circular_read_stats')
      .select('*'),
  ]);

  const statsMap = new Map((statsRes.data || []).map((s: any) => [s.circular_id, s]));
  const circularsWithStats = (circularsRes.data || []).map((c: any) => ({
    ...c,
    stats: statsMap.get(c.id) || null,
  }));

  return {
    circulars: circularsWithStats,
    segments: segmentsRes.data || [],
    campuses: campusesRes.data || [],
  };
}

export async function createCircularAction(payload: CreateCircularPayload) {
  const supabase = await supabaseServer();

  // Validate title
  if (!payload.title || !payload.title.trim()) {
    return { success: false, error: 'Circular title is required.' };
  }

  // Validate bilingual body (at least one must be provided)
  const hasEn = payload.body_en && payload.body_en.trim().length > 0;
  const hasUr = payload.body_ur && payload.body_ur.trim().length > 0;
  if (!hasEn && !hasUr) {
    return { success: false, error: 'At least one body content (English or Urdu) is required.' };
  }

  // AC 1: Validate attachments count
  const attachments = payload.attachments || [];
  if (attachments.length > MAX_ATTACHMENTS_PER_CIRCULAR) {
    return {
      success: false,
      error: `MAX_ATTACHMENTS_EXCEEDED: A circular can have at most ${MAX_ATTACHMENTS_PER_CIRCULAR} attachments.`,
    };
  }

  // AC 1: Validate attachment file sizes
  for (const att of attachments) {
    if (att.size_bytes > MAX_ATTACHMENT_SIZE_BYTES) {
      return {
        success: false,
        error: `Attachment "${att.file_name}" (${(att.size_bytes / 1024 / 1024).toFixed(2)} MB) exceeds the maximum allowed limit of 10 MB.`,
      };
    }
  }

  // Get active tenant
  const { data: tenantData } = await supabase.rpc('app.auth_tenant_id' as any);
  // Or fetch tenant_id from first campus if RPC name is schema-qualified
  const { data: userData } = await supabase.auth.getUser();
  const userId = userData.user?.id;

  const client = supabase as any;

  let tenantId: string | undefined = undefined;
  if (userId) {
    const { data: userApp } = await client
      .from('app_user')
      .select('tenant_id')
      .eq('user_id', userId)
      .maybeSingle();
    tenantId = userApp?.tenant_id;
  }

  // Insert circular
  const { data: circData, error: circError } = await client
    .from('circular')
    .insert({
      title: payload.title.trim(),
      body_en: payload.body_en?.trim() || null,
      body_ur: payload.body_ur?.trim() || null,
      campus_id: payload.campus_id || null,
      publish_at: payload.publish_at || new Date().toISOString(),
      expires_at: payload.expires_at || null,
      status: payload.status || 'draft',
      created_by: userId,
      ...(tenantId ? { tenant_id: tenantId } : {}),
    } as any)
    .select()
    .single();

  if (circError || !circData) {
    return { success: false, error: circError?.message || 'Failed to create circular.' };
  }

  const circularId = (circData as any).id;

  // Insert attachments if any
  if (attachments.length > 0) {
    const attachmentRows = attachments.map((att) => ({
      circular_id: circularId,
      storage_path: att.storage_path,
      file_name: att.file_name,
      mime_type: att.mime_type,
      size_bytes: att.size_bytes,
    }));

    const { error: attError } = await client
      .from('circular_attachment')
      .insert(attachmentRows as any);

    if (attError) {
      return { success: false, error: attError.message };
    }
  }

  // Insert targeted segments if any
  if (payload.segment_ids && payload.segment_ids.length > 0) {
    const audienceRows = payload.segment_ids.map((segId) => ({
      circular_id: circularId,
      segment_id: segId,
    }));

    const { error: audError } = await client
      .from('circular_audience')
      .insert(audienceRows as any);

    if (audError) {
      return { success: false, error: audError.message };
    }
  }

  revalidatePath('/communication/circulars');
  revalidatePath('/portal/circulars');
  return { success: true, circular: circData };
}

export async function publishCircularAction(circularId: string, publishAt?: string) {
  const supabase = await supabaseServer();

  const { data, error } = await supabase.rpc('publish_circular' as any, {
    p_circular_id: circularId,
    p_publish_at: publishAt || new Date().toISOString(),
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/circulars');
  revalidatePath('/portal/circulars');
  return { success: true, circular: data };
}

export async function unpublishCircularAction(circularId: string) {
  const supabase = await supabaseServer();

  const { data, error } = await supabase.rpc('unpublish_circular' as any, {
    p_circular_id: circularId,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/circulars');
  revalidatePath('/portal/circulars');
  return { success: true, circular: data };
}

export async function fetchCircularStatsAction(circularId: string) {
  const supabase = await supabaseServer();
  const client = supabase as any;

  const [statsRes, unreadRes] = await Promise.all([
    client
      .from('v_circular_read_stats')
      .select('*')
      .eq('circular_id', circularId)
      .single(),
    client
      .from('v_circular_unread_guardians')
      .select('*')
      .eq('circular_id', circularId),
  ]);

  return {
    stats: statsRes.data || null,
    unreadGuardians: unreadRes.data || [],
  };
}

export async function exportUnreadSegmentAction(circularId: string, segmentName: string) {
  const supabase = await supabaseServer();

  if (!segmentName || !segmentName.trim()) {
    return { success: false, error: 'Segment name is required.' };
  }

  const { data, error } = await (supabase as any).rpc('export_circular_unread_segment', {
    p_circular_id: circularId,
    p_segment_name: segmentName.trim(),
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/segments');
  revalidatePath('/communication/circulars');
  return { success: true, segmentId: data };
}

export async function recordCircularReadAction(circularId: string, guardianId?: string) {
  const supabase = await supabaseServer();

  const { data, error } = await (supabase as any).rpc('mark_circular_read', {
    p_circular_id: circularId,
    p_guardian_id: guardianId || null,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  return { success: true, receipt: data };
}

