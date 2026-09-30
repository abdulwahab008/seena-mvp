'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export async function createTicketAction(formData: FormData) {
  const supabase = await supabaseServer();

  const campusId = formData.get('campus_id') as string;
  const category = formData.get('category') as string;
  const subject = (formData.get('subject') as string)?.trim();
  const description = (formData.get('description') as string)?.trim();
  const studentId = (formData.get('student_id') as string) || undefined;

  if (!campusId || !category || !subject || !description) {
    return { error: 'Please provide all required fields.' };
  }

  if (subject.length < 3) {
    return { error: 'Subject must be at least 3 characters.' };
  }

  const { data, error } = await supabase.rpc('create_support_ticket', {
    p_campus_id: campusId,
    p_category: category as any,
    p_subject: subject,
    p_description: description,
    p_student_id: studentId,
    p_sla_hours: 48,
  });

  if (error) {
    return { error: error.message };
  }

  revalidatePath('/portal/tickets');
  revalidatePath('/staff/tickets');
  return { success: true, ticket: data };
}

export async function addTicketMessageAction(formData: FormData) {
  const supabase = await supabaseServer();

  const ticketId = formData.get('ticket_id') as string;
  const body = (formData.get('body') as string)?.trim();
  const isInternal = formData.get('is_internal') === 'true';

  if (!ticketId || !body) {
    return { error: 'Message body cannot be empty.' };
  }

  const { data, error } = await supabase.rpc('add_ticket_message', {
    p_ticket_id: ticketId,
    p_body: body,
    p_is_internal: isInternal,
  });

  if (error) {
    return { error: error.message };
  }

  revalidatePath(`/portal/tickets/${ticketId}`);
  revalidatePath(`/staff/tickets/${ticketId}`);
  revalidatePath('/portal/tickets');
  revalidatePath('/staff/tickets');
  return { success: true, messageId: data };
}

export async function resolveTicketAction(formData: FormData) {
  const supabase = await supabaseServer();

  const ticketId = formData.get('ticket_id') as string;
  const resolutionNote = (formData.get('resolution_note') as string)?.trim();

  if (!ticketId) {
    return { error: 'Ticket ID is required.' };
  }

  const { error } = await supabase.rpc('resolve_ticket', {
    p_ticket_id: ticketId,
    p_resolution_note: resolutionNote || undefined,
  });

  if (error) {
    return { error: error.message };
  }

  revalidatePath(`/portal/tickets/${ticketId}`);
  revalidatePath(`/staff/tickets/${ticketId}`);
  revalidatePath('/portal/tickets');
  revalidatePath('/staff/tickets');
  return { success: true };
}

export async function reopenTicketAction(formData: FormData) {
  const supabase = await supabaseServer();

  const ticketId = formData.get('ticket_id') as string;
  const reason = (formData.get('reason') as string)?.trim();

  if (!ticketId || !reason) {
    return { error: 'Please state a reason for reopening.' };
  }

  const { error } = await supabase.rpc('reopen_ticket', {
    p_ticket_id: ticketId,
    p_reason: reason,
  });

  if (error) {
    return { error: error.message };
  }

  revalidatePath(`/portal/tickets/${ticketId}`);
  revalidatePath(`/staff/tickets/${ticketId}`);
  revalidatePath('/portal/tickets');
  revalidatePath('/staff/tickets');
  return { success: true };
}
