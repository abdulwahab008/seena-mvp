'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionResponse = {
  success: boolean;
  message?: string;
  data?: any;
  error?: string;
};

export async function submitRemarkAction(
  studentId: string,
  body: string,
  language: 'en' | 'ur' = 'en'
): Promise<ActionResponse> {
  if (!studentId) return { success: false, error: 'Student is required' };
  if (!body || !body.trim()) return { success: false, error: 'Remark body cannot be empty' };

  const supabase = await supabaseServer();
  const { data, error } = await (supabase as any).rpc('submit_student_remark', {
    p_student_id: studentId,
    p_body: body.trim(),
    p_language: language,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/staff/remarks');
  revalidatePath('/portal/remarks');
  return { success: true, data };
}

export async function editRemarkAction(
  remarkId: string,
  body: string,
  language: 'en' | 'ur' = 'en'
): Promise<ActionResponse> {
  if (!remarkId) return { success: false, error: 'Remark ID is required' };
  if (!body || !body.trim()) return { success: false, error: 'Remark body cannot be empty' };

  const supabase = await supabaseServer();
  const { data, error } = await (supabase as any).rpc('edit_student_remark', {
    p_remark_id: remarkId,
    p_body: body.trim(),
    p_language: language,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/staff/remarks');
  revalidatePath('/portal/remarks');
  return { success: true, data };
}

export async function moderateRemarkAction(
  versionId: string,
  action: 'approved' | 'rejected',
  reason?: string
): Promise<ActionResponse> {
  if (!versionId) return { success: false, error: 'Version ID is required' };
  if (action === 'rejected' && (!reason || !reason.trim())) {
    return { success: false, error: 'Rejection reason is mandatory when rejecting a remark' };
  }

  const supabase = await supabaseServer();
  const { data, error } = await (supabase as any).rpc('moderate_student_remark', {
    p_version_id: versionId,
    p_action: action,
    p_reason: reason?.trim() || null,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/staff/remarks');
  revalidatePath('/portal/remarks');
  return { success: true, data };
}

export async function toggleCampusPolicyAction(
  campusId: string,
  requireApproval: boolean
): Promise<ActionResponse> {
  if (!campusId) return { success: false, error: 'Campus ID is required' };

  const supabase = await supabaseServer();
  const { error } = await (supabase as any)
    .from('campus_portal_policy')
    .upsert({
      campus_id: campusId,
      require_remark_approval: requireApproval,
      updated_at: new Date().toISOString(),
    });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/staff/remarks');
  return { success: true };
}
