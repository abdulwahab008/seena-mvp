'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { hostelAddRoomSchema, hostelBlockSchema, hostelBlockUpdateSchema, hostelRoomUpdateSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  BLOCK_CODE_EXISTS: 'A block with this code already exists on this campus.',
  BLOCK_SIZE_INVALID: 'Check the number of rooms and beds.',
  BED_OCCUPIED: 'A bed that would be removed is occupied (BED_OCCUPIED). Vacate it first.',
  ROOM_EXISTS: 'That room number already exists in this block.',
  ROOM_NOT_FOUND: 'That room no longer exists.',
  BLOCK_NOT_FOUND: 'That block no longer exists.',
  STAFF_NOT_FOUND: 'The selected warden was not found.',
};

export async function createBlock(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelBlockSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('create_hostel_block', {
    p_campus_id: p.data.campusId, p_code: p.data.code, p_name: p.data.name, p_gender: p.data.gender, p_rooms: p.data.rooms,
    p_beds_per_room: p.data.bedsPerRoom, p_rooms_per_floor: p.data.roomsPerFloor, p_room_type: p.data.roomType, p_warden_staff_id: p.data.wardenStaffId,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel');
  return { error: null, message: `Block created with ${p.data.rooms * p.data.bedsPerRoom} beds.` };
}

export async function updateBlock(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelBlockUpdateSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('update_hostel_block', { p_block_id: p.data.blockId, p_name: p.data.name, p_warden_staff_id: p.data.wardenStaffId, p_active: p.data.active });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel');
  return { error: null, message: 'Block updated.' };
}

export async function updateRoom(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelRoomUpdateSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('update_hostel_room', { p_room_id: p.data.roomId, p_bed_count: p.data.bedCount, p_room_type: p.data.roomType, p_status: p.data.status });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel');
  return { error: null, message: 'Room updated.' };
}

export async function addRoom(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelAddRoomSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('add_hostel_room', { p_block_id: p.data.blockId, p_room_no: p.data.roomNo, p_bed_count: p.data.bedCount, p_room_type: p.data.roomType, p_floor: p.data.floor });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel');
  return { error: null, message: 'Room added.' };
}
