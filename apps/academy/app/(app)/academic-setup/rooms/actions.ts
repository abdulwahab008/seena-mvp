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

// Update existing room details (name, code, room type, capacity, block)
export async function updateRoom(roomId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createRoomSchema.safeParse({
    code: formData.get('code'),
    name: formData.get('name'),
    roomType: formData.get('roomType'),
    capacity: formData.get('capacity'),
    blockLabel: formData.get('blockLabel') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await (supabase.rpc as any)('update_room', {
    p_id: roomId,
    p_code: parsed.data.code,
    p_name: parsed.data.name,
    p_room_type: parsed.data.roomType,
    p_capacity: parsed.data.capacity,
    p_block_label: parsed.data.blockLabel ?? null,
  });
  if (error) {
    if (error.message.includes('ROOM_CODE_DUPLICATE')) return { error: `A room coded "${parsed.data.code}" already exists at this campus.` };
    if (error.message.includes('CAPACITY_MUST_BE_POSITIVE')) return { error: 'Capacity must be at least 1.' };
    if (error.message.includes('ROOM_NOT_FOUND')) return { error: 'Room not found.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to modify rooms.' };
    return { error: 'Could not update the room.' };
  }

  revalidatePath('/academic-setup/rooms');
  return { error: null };
}

// FR-E10: activate/deactivate a room — never deletes (preserves historical timetable records)
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

// Batch generate classrooms for a class (e.g. Class 10 -> Jinnah, Iqbal, Fatima)
export async function batchCreateClassrooms(
  campusId: string,
  data: {
    classLevelId?: string;
    classCode: string;
    className: string;
    sectionNames: string[];
    capacity: number;
    blockLabel?: string;
    linkHomeroom?: boolean;
  }
): Promise<{ error: string | null; count?: number }> {
  if (!data.sectionNames || data.sectionNames.length === 0) {
    return { error: 'Please specify at least one section name.' };
  }
  if (!data.capacity || data.capacity < 1) {
    return { error: 'Capacity must be at least 1.' };
  }

  const supabase = await supabaseServer();

  // Find existing sections for this class at this campus
  let existingSections: Array<{ id: string; name: string; home_room_id: string | null }> = [];
  if (data.classLevelId) {
    const { data: secs } = await supabase
      .from('class_section')
      .select('id, name, home_room_id')
      .eq('campus_id', campusId)
      .eq('class_level_id', data.classLevelId);
    if (secs) existingSections = secs;
  }

  let createdCount = 0;
  for (const rawName of data.sectionNames) {
    const secName = rawName.trim();
    if (!secName) continue;

    // Generate room code: e.g. 10-JIN, 10-IQB, 10-A
    const cleanSecCode = secName.replace(/[^A-Za-z0-9]/g, '').slice(0, 4).toUpperCase();
    const cleanClassCode = (data.classCode || 'CR').replace(/[^A-Za-z0-9]/g, '');
    let roomCode = `${cleanClassCode}-${cleanSecCode}`;
    const roomName = `${data.className} - Section ${secName}`;

    // Attempt room creation
    const { data: roomId, error: roomError } = await supabase.rpc('create_room', {
      p_campus_id: campusId,
      p_code: roomCode,
      p_name: roomName,
      p_room_type: 'CLASSROOM',
      p_capacity: data.capacity,
      p_block_label: data.blockLabel || undefined,
    });

    let finalRoomId: string | null = (roomId as string) || null;

    if (roomError) {
      if (roomError.message.includes('ROOM_CODE_DUPLICATE')) {
        // Try unique suffix
        const altCode = `${cleanClassCode}-${cleanSecCode}-${Math.floor(Math.random() * 90 + 10)}`;
        const { data: rId2, error: err2 } = await supabase.rpc('create_room', {
          p_campus_id: campusId,
          p_code: altCode,
          p_name: roomName,
          p_room_type: 'CLASSROOM',
          p_capacity: data.capacity,
          p_block_label: data.blockLabel || undefined,
        });
        if (!err2 && rId2) {
          finalRoomId = rId2 as string;
          createdCount++;
        }
      }
    } else if (roomId) {
      createdCount++;
    }

    // Link homeroom if requested and matched
    if (finalRoomId && data.linkHomeroom) {
      const matchSec = existingSections.find((s) => s.name.toLowerCase() === secName.toLowerCase());
      if (matchSec) {
        await supabase.from('class_section').update({ home_room_id: finalRoomId }).eq('id', matchSec.id);
      }
    }
  }

  revalidatePath('/academic-setup/rooms');
  revalidatePath('/academic-setup/classes-sections');
  return { error: null, count: createdCount };
}

// 1-Click Standard Facilities Seeding (Physics, Chemistry, Biology, Computer Labs, Library, Exam Hall, Prayer Area)
export async function seedStandardFacilities(campusId: string): Promise<{ error: string | null; count?: number }> {
  const supabase = await supabaseServer();

  const standardFacilities = [
    { code: 'SL-PHY', name: 'Physics Laboratory', type: 'SCIENCE_LAB' as const, capacity: 30, block: 'Science Wing' },
    { code: 'SL-CHM', name: 'Chemistry Laboratory', type: 'SCIENCE_LAB' as const, capacity: 30, block: 'Science Wing' },
    { code: 'SL-BIO', name: 'Biology Laboratory', type: 'SCIENCE_LAB' as const, capacity: 30, block: 'Science Wing' },
    { code: 'CL-1', name: 'Central Computer Lab', type: 'COMPUTER_LAB' as const, capacity: 35, block: 'IT Block' },
    { code: 'LIB-1', name: 'Main School Library', type: 'LIBRARY' as const, capacity: 50, block: 'Academic Block' },
    { code: 'HALL-1', name: 'Examination & Event Hall', type: 'HALL' as const, capacity: 120, block: 'Main Block' },
    { code: 'PR-1', name: 'Prayer Area / Mosque', type: 'PRAYER_AREA' as const, capacity: 100, block: null },
  ];

  let added = 0;
  for (const fac of standardFacilities) {
    const { error } = await supabase.rpc('create_room', {
      p_campus_id: campusId,
      p_code: fac.code,
      p_name: fac.name,
      p_room_type: fac.type,
      p_capacity: fac.capacity,
      p_block_label: fac.block || undefined,
    });
    if (!error) {
      added++;
    }
  }

  revalidatePath('/academic-setup/rooms');
  return { error: null, count: added };
}
