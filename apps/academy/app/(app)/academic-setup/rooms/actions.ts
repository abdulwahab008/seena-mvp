'use server';

import { revalidatePath } from 'next/cache';
import { createRoomSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

// FR-E10: create a room. Capacity and per-campus code uniqueness are the
// DB's own job (create_room's CAPACITY_MUST_BE_POSITIVE and
// ROOM_CODE_DUPLICATE) — this action only shapes the client-facing error.
export async function createRoom(campusId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createRoomSchema.safeParse({
    code: formData.get('code'),
    name: formData.get('name'),
    roomType: formData.get('roomType'),
    capacity: formData.get('capacity'),
    blockLabel: formData.get('blockLabel') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_room', {
    p_campus_id: campusId,
    p_code: parsed.data.code,
    p_name: parsed.data.name,
    p_room_type: parsed.data.roomType,
    p_capacity: parsed.data.capacity,
    p_block_label: parsed.data.blockLabel,
  });
  if (error) {
    if (error.message.includes('ROOM_CODE_DUPLICATE')) return { error: `A room coded "${parsed.data.code}" already exists at this campus.` };
    if (error.message.includes('CAPACITY_MUST_BE_POSITIVE')) return { error: 'Capacity must be at least 1.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to create rooms.' };
    return { error: 'Could not create the room.' };
  }

  revalidatePath('/academic-setup/rooms');
  return { error: null };
}

// FR-E10: activate/deactivate a room — never deletes (no real usage check
// exists yet, see the migration header — Module F/Timetable isn't built).
export async function setRoomActive(id: string, isActive: boolean, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_room_active', { p_id: id, p_is_active: isActive });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to change rooms.' };
    if (error.message.includes('ROOM_NOT_FOUND')) return { error: 'Room not found.' };
    return { error: 'Could not update the room.' };
  }

  revalidatePath('/academic-setup/rooms');
  return { error: null };
}
