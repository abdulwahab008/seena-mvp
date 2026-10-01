'use server';

import { revalidatePath } from 'next/cache';
import { clockOffsetSchema, mapDeviceCodeSchema, registerBiometricDeviceSchema, staffAttendanceRuleSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type BiometricState = { error: string | null; message?: string | null; apiKey?: string | null; serial?: string | null };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'Only HR can manage biometric devices.';
  if (message.includes('DEVICE_SERIAL_TAKEN')) return 'A device with that serial is already registered.';
  if (message.includes('DEVICE_CODE_TAKEN')) return 'That code is already mapped to another staff member on this device.';
  if (message.includes('DEVICE_NOT_FOUND')) return 'Device not found.';
  if (message.includes('STAFF_NOT_FOUND')) return 'Staff member not found.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  return 'Something went wrong. Please try again.';
}

export async function registerDevice(_prev: BiometricState, formData: FormData): Promise<BiometricState> {
  const p = registerBiometricDeviceSchema.safeParse({ campusId: formData.get('campusId'), deviceSerial: formData.get('deviceSerial'), label: formData.get('label') || undefined });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('register_biometric_device', { p_campus_id: p.data.campusId, p_device_serial: p.data.deviceSerial, p_label: p.data.label });
  if (error) return { error: mapError(error.message) };
  const row = Array.isArray(data) ? data[0] : data;
  revalidatePath('/staff/biometric');
  // The raw key is returned exactly once: only its sha256 is stored.
  return { error: null, message: 'Device registered.', apiKey: row?.api_key ?? null, serial: p.data.deviceSerial };
}

export async function mapDeviceCode(_prev: BiometricState, formData: FormData): Promise<BiometricState> {
  const p = mapDeviceCodeSchema.safeParse({ deviceId: formData.get('deviceId'), staffId: formData.get('staffId'), code: formData.get('code') });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('map_staff_device_code', { p_device_id: p.data.deviceId, p_staff_device_code: p.data.code, p_staff_id: p.data.staffId });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/staff/biometric');
  return { error: null, message: data && data > 0 ? `Code mapped; ${data} waiting punch(es) released into the register.` : 'Code mapped.' };
}

export async function setClockOffset(_prev: BiometricState, formData: FormData): Promise<BiometricState> {
  const p = clockOffsetSchema.safeParse({ deviceId: formData.get('deviceId'), offsetSeconds: formData.get('offsetSeconds') });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_biometric_device_clock_offset', { p_device_id: p.data.deviceId, p_offset_seconds: p.data.offsetSeconds });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/staff/biometric');
  return { error: null, message: 'Clock offset saved.' };
}

export async function saveAttendanceRule(_prev: BiometricState, formData: FormData): Promise<BiometricState> {
  const p = staffAttendanceRuleSchema.safeParse({ campusId: formData.get('campusId'), startTime: formData.get('startTime'), graceMinutes: formData.get('graceMinutes') });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_campus_staff_attendance_rule', { p_campus_id: p.data.campusId, p_start_time: p.data.startTime, p_grace_minutes: p.data.graceMinutes });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/staff/biometric');
  return { error: null, message: 'Start time and grace period saved.' };
}
