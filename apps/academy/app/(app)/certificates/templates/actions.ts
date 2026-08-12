'use server';

import { revalidatePath } from 'next/cache';
import { createCertificateTemplateSchema, saveCertificateTemplateSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

const PATH = '/certificates/templates';

export type TemplateMutationState = {
  error: string | null;
  templateId?: string;
  /** AC1: the fields activation refused, straight from the database's own report. */
  unknownFields?: string[];
  missingRequiredFields?: string[];
};

function permissionMessage(message: string): string | null {
  if (message.includes('FORBIDDEN')) return 'You do not have permission to author this template.';
  if (message.includes('TEMPLATE_NOT_FOUND')) return 'Template not found.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  return null;
}

export async function createCertificateTemplate(formData: FormData): Promise<TemplateMutationState> {
  const parsed = createCertificateTemplateSchema.safeParse({
    certificateType: formData.get('certificateType'),
    title: formData.get('title'),
    bodyHtml: formData.get('bodyHtml'),
    boardCode: formData.get('boardCode') ?? '',
    language: formData.get('language'),
    pageSize: formData.get('pageSize'),
    campusId: formData.get('campusId') ?? '',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('create_certificate_template', {
    p_certificate_type: parsed.data.certificateType,
    p_title: parsed.data.title,
    p_body_html: parsed.data.bodyHtml,
    p_board_code: parsed.data.boardCode || undefined,
    p_language: parsed.data.language,
    p_page_size: parsed.data.pageSize,
    p_campus_id: parsed.data.campusId || undefined,
  });
  if (error || !data) {
    if (error?.code === '23505') return { error: 'A template with that type, board and language already exists at this scope.' };
    return { error: (error && permissionMessage(error.message)) ?? 'Could not create the template.' };
  }

  revalidatePath(PATH);
  return { error: null, templateId: data as string };
}

// AC2: the returned id is not necessarily the id that was passed in —
// save_certificate_template() reports the row the edit actually landed on,
// which is a brand-new draft version whenever the edited template was
// already activated.
export async function saveCertificateTemplate(formData: FormData): Promise<TemplateMutationState> {
  const parsed = saveCertificateTemplateSchema.safeParse({
    templateId: formData.get('templateId'),
    title: formData.get('title'),
    bodyHtml: formData.get('bodyHtml'),
    pageSize: formData.get('pageSize'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_certificate_template', {
    p_template_id: parsed.data.templateId,
    p_title: parsed.data.title,
    p_body_html: parsed.data.bodyHtml,
    p_page_size: parsed.data.pageSize,
  });
  if (error || !data) return { error: (error && permissionMessage(error.message)) ?? 'Could not save the template.' };

  revalidatePath(PATH);
  return { error: null, templateId: data as string };
}

export async function activateCertificateTemplate(templateId: string): Promise<TemplateMutationState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('activate_certificate_template', { p_template_id: templateId });
  if (!error) {
    revalidatePath(PATH);
    return { error: null, templateId };
  }

  // AC1: the Principal has to be told WHICH field was refused. The
  // exception carries it in DETAIL, but the same report is available as a
  // structured read, so the message is built from that rather than from
  // parsing an error string.
  if (error.message.includes('MERGE_FIELD_NOT_ALLOWED') || error.message.includes('MERGE_FIELD_REQUIRED_MISSING')) {
    const { data: report } = await supabase.rpc('validate_certificate_template', { p_template_id: templateId });
    const parsedReport = (report ?? {}) as { unknown_fields?: string[]; missing_required_fields?: string[] };
    const unknownFields = parsedReport.unknown_fields ?? [];
    const missingRequiredFields = parsedReport.missing_required_fields ?? [];
    const parts: string[] = [];
    if (unknownFields.length > 0) parts.push(`unknown merge field${unknownFields.length === 1 ? '' : 's'}: ${unknownFields.join(', ')}`);
    if (missingRequiredFields.length > 0) parts.push(`required field${missingRequiredFields.length === 1 ? '' : 's'} missing: ${missingRequiredFields.join(', ')}`);
    return { error: `Activation rejected — ${parts.join('; ')}.`, unknownFields, missingRequiredFields };
  }

  if (error.code === '23505') return { error: 'Another version of this template is already active.' };
  if (error.message.includes('TEMPLATE_NOT_DRAFT')) return { error: 'Only a draft version can be activated.' };
  return { error: permissionMessage(error.message) ?? 'Could not activate the template.' };
}
