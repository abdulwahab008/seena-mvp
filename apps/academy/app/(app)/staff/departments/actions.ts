'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

const DepartmentSchema = z.object({
  id: z.string().uuid().optional().or(z.literal('')),
  code: z
    .string()
    .min(2, 'Code must be at least 2 characters (e.g. SCI, MATH)')
    .max(10, 'Code max 10 characters')
    .regex(/^[A-Za-z0-9_]+$/, 'Code can only contain letters, numbers, and underscores'),
  nameEn: z.string().min(2, 'English name must be at least 2 characters').max(100),
  nameUr: z.string().max(100).optional(),
});

export async function upsertDepartmentAction(formData: FormData): Promise<{
  error: string | null;
  data?: { id: string; code: string; name_en: string; name_ur?: string | null };
}> {
  const idVal = formData.get('id');
  const parsed = DepartmentSchema.safeParse({
    id: idVal ? String(idVal) : undefined,
    code: formData.get('code'),
    nameEn: formData.get('nameEn'),
    nameUr: formData.get('nameUr') || undefined,
  });

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid department input.' };
  }

  const supabase = await supabaseServer();
  const { data, error } = await (supabase.rpc as any)('upsert_department', {
    p_code: parsed.data.code.toUpperCase(),
    p_name_en: parsed.data.nameEn.trim(),
    p_name_ur: parsed.data.nameUr?.trim() || null,
    p_id: parsed.data.id || null,
  });

  if (error) {
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'You do not have permission to manage academic departments.' };
    }
    return { error: error.message || 'Failed to save academic department.' };
  }

  revalidatePath('/staff/departments');
  revalidatePath('/staff');
  revalidatePath('/staff/directory');
  return { error: null, data: data as any };
}

export async function deleteDepartmentAction(departmentId: string): Promise<{ error: string | null }> {
  if (!departmentId) return { error: 'Department ID is required.' };

  const supabase = await supabaseServer();
  const { error } = await (supabase.rpc as any)('delete_department', {
    p_id: departmentId,
  });

  if (error) {
    if (error.message.includes('DEPARTMENT_IN_USE')) {
      return { error: 'Cannot delete department with active assigned faculty. Reassign teachers first.' };
    }
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'You do not have permission to delete academic departments.' };
    }
    return { error: error.message || 'Failed to delete academic department.' };
  }

  revalidatePath('/staff/departments');
  revalidatePath('/staff');
  revalidatePath('/staff/directory');
  return { error: null };
}

export async function assignStaffDepartmentAction(
  staffId: string,
  departmentId: string | null,
): Promise<{ error: string | null }> {
  if (!staffId) return { error: 'Staff ID is required.' };

  const supabase = await supabaseServer();
  const { error } = await (supabase.rpc as any)('assign_staff_department', {
    p_staff_id: staffId,
    p_department_id: departmentId || null,
  });

  if (error) {
    return { error: error.message || 'Failed to assign department.' };
  }

  revalidatePath('/staff/departments');
  revalidatePath('/staff');
  revalidatePath('/staff/directory');
  return { error: null };
}

export async function getUnassignedStaffAction(): Promise<{
  error: string | null;
  data: { id: string; employee_code: string; full_name: string }[];
}> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase
    .from('staff')
    .select('id, employee_code, full_name, department_id')
    .eq('employment_status', 'active')
    .is('department_id', null)
    .order('full_name', { ascending: true });

  if (error) {
    return { error: error.message, data: [] };
  }
  return {
    error: null,
    data: (data ?? []).map((s) => ({
      id: s.id,
      employee_code: s.employee_code,
      full_name: s.full_name,
    })),
  };
}

