'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { sniffMime } from '@/lib/uploads/sniff';

type Kind = 'student' | 'staff';
type Result = { error: string | null };

const BUCKET = { student: 'student-photos', staff: 'staff-photos' } as const;
const PAGE = { student: (id: string) => `/students/${id}`, staff: (id: string) => `/staff/${id}` } as const;
const EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' } as const;
const MAX_BYTES = 2 * 1024 * 1024;

function message(code: string | undefined): string {
  if (code?.includes('FORBIDDEN')) return 'You are not allowed to change this photo.';
  return 'The photo could not be saved.';
}

async function setPath(kind: Kind, id: string, path: string | null) {
  const supabase = await supabaseServer();
  return kind === 'student'
    ? supabase.rpc('set_student_photo', { p_student_id: id, p_path: path })
    : supabase.rpc('set_staff_photo', { p_staff_id: id, p_path: path });
}

export async function uploadPhoto(kind: Kind, id: string, formData: FormData): Promise<Result> {
  const file = formData.get('photo');
  if (!(file instanceof File) || file.size === 0) return { error: 'Choose a photo.' };
  if (file.size > MAX_BYTES) return { error: 'The photo must be 2 MB or smaller.' };
  const bytes = new Uint8Array(await file.arrayBuffer());
  const mime = sniffMime(bytes);
  if (mime !== 'image/jpeg' && mime !== 'image/png' && mime !== 'image/webp') return { error: 'The photo must be a JPEG, PNG or WebP image.' };

  const supabase = await supabaseServer();
  const { data: record } = await (kind === 'student'
    ? supabase.from('student').select('tenant_id, campus_id').eq('id', id).maybeSingle()
    : supabase.from('staff').select('tenant_id, campus_id').eq('id', id).maybeSingle());
  if (!record) return { error: 'Record not found.' };

  const path = `${record.tenant_id}/${record.campus_id}/${id}-${Date.now()}.${EXT[mime]}`;
  const storage = supabase.storage.from(BUCKET[kind]);
  const { error: upErr } = await storage.upload(path, bytes, { contentType: mime });
  if (upErr) return { error: message(upErr.message) };

  const { data: old, error } = await setPath(kind, id, path);
  if (error) {
    await storage.remove([path]);
    return { error: message(error.message) };
  }
  if (old) await storage.remove([old]);
  revalidatePath(PAGE[kind](id));
  return { error: null };
}

export async function removePhoto(kind: Kind, id: string): Promise<Result> {
  const { data: old, error } = await setPath(kind, id, null);
  if (error) return { error: message(error.message) };
  if (old) {
    const supabase = await supabaseServer();
    await supabase.storage.from(BUCKET[kind]).remove([old]);
  }
  revalidatePath(PAGE[kind](id));
  return { error: null };
}
