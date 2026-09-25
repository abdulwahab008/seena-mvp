'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export interface CampusEventInput {
  title: string;
  description?: string;
  campus_id?: string | null; // null = tenant-wide
  event_type: 'holiday' | 'exam' | 'ptm' | 'sports' | 'cultural' | 'academic' | 'other';
  starts_at: string;
  ends_at: string;
  is_all_day?: boolean;
  hijri_label?: string;
}

export interface CampusEventOverrideInput {
  event_id: string;
  campus_id: string;
  override_type?: 'modified' | 'cancelled' | 'rescheduled';
  title?: string;
  description?: string;
  starts_at?: string;
  ends_at?: string;
  is_cancelled?: boolean;
  reason?: string;
}

export async function fetchCampusEventsDashboardData() {
  const supabase = await supabaseServer();
  const client = supabase as any;

  const [eventsRes, campusesRes, overridesRes] = await Promise.all([
    client
      .from('v_effective_campus_events')
      .select('*')
      .order('starts_at', { ascending: true }),
    client
      .from('campus')
      .select('id, name, code')
      .order('name'),
    client
      .from('campus_event_override')
      .select('*'),
  ]);

  return {
    events: eventsRes.data || [],
    campuses: campusesRes.data || [],
    overrides: overridesRes.data || [],
  };
}

export async function createCampusEventAction(payload: CampusEventInput) {
  const supabase = await supabaseServer();
  const client = supabase as any;

  if (!payload.title || !payload.title.trim()) {
    return { success: false, error: 'Event title is required.' };
  }

  if (!payload.starts_at || !payload.ends_at) {
    return { success: false, error: 'Start and end dates are required.' };
  }

  if (new Date(payload.ends_at) < new Date(payload.starts_at)) {
    return { success: false, error: 'End date cannot be earlier than start date.' };
  }

  // AC 4: Check if retroactive holiday
  const isPast = new Date(payload.starts_at) < new Date();
  const isRetroactiveHoliday = isPast && payload.event_type === 'holiday';

  // Get current user auth
  const { data: userData } = await supabase.auth.getUser();
  const userId = userData?.user?.id;

  // Tenant id resolution
  const { data: userProfile } = await client
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', userId)
    .single();

  const tenantId = userProfile?.tenant_id;

  const insertData = {
    tenant_id: tenantId,
    campus_id: payload.campus_id || null,
    title: payload.title.trim(),
    description: payload.description?.trim() || null,
    event_type: payload.event_type,
    starts_at: payload.starts_at,
    ends_at: payload.ends_at,
    is_all_day: payload.is_all_day ?? true,
    hijri_label: payload.hijri_label?.trim() || null,
    created_by: userId || null,
  };

  const { data, error } = await client
    .from('campus_event')
    .insert(insertData)
    .select()
    .single();

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/calendar');
  revalidatePath('/portal/calendar');

  return {
    success: true,
    event: data,
    isRetroactiveHoliday,
  };
}

export async function createCampusEventOverrideAction(payload: CampusEventOverrideInput) {
  const supabase = await supabaseServer();
  const client = supabase as any;

  if (!payload.event_id || !payload.campus_id) {
    return { success: false, error: 'Event ID and Campus ID are required.' };
  }

  const { data, error } = await client
    .from('campus_event_override')
    .upsert(
      {
        event_id: payload.event_id,
        campus_id: payload.campus_id,
        override_type: payload.override_type || 'modified',
        title: payload.title || null,
        description: payload.description || null,
        starts_at: payload.starts_at || null,
        ends_at: payload.ends_at || null,
        is_cancelled: payload.is_cancelled ?? false,
        reason: payload.reason || null,
        updated_at: new Date().toISOString(),
      },
      { onConflict: 'event_id, campus_id' }
    )
    .select()
    .single();

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/calendar');
  revalidatePath('/portal/calendar');

  return { success: true, override: data };
}

export async function generateGuardianIcsTokenAction(guardianId?: string) {
  const supabase = await supabaseServer();
  const client = supabase as any;

  const { data, error } = await client.rpc('generate_guardian_ics_token', {
    p_guardian_id: guardianId || null,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  return { success: true, token: data };
}

export async function revokeGuardianIcsTokenAction(token: string) {
  const supabase = await supabaseServer();
  const client = supabase as any;

  const { data, error } = await client.rpc('revoke_guardian_ics_token', {
    p_token: token,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  return { success: true, isRevoked: data };
}

export async function recomputeRetroactiveHolidayAction(eventId: string) {
  const supabase = await supabaseServer();
  const client = supabase as any;

  const { data, error } = await client.rpc('recompute_past_holiday_impact', {
    p_event_id: eventId,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  return { success: true, result: data };
}
