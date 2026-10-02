'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type CommRecipientType = 'parent' | 'guardian' | 'student' | 'staff' | 'custom';
export type MessageClass = 'transactional' | 'promotional' | 'emergency' | 'reminder';
export type SmsEncoding = 'auto' | 'gsm7' | 'ucs2';

export type MessageTemplateVersionRow = {
  id: string;
  template_id: string;
  version_no: number;
  message_class: MessageClass;
  body_en: string;
  body_ur: string | null;
  sms_encoding: SmsEncoding;
  is_published: boolean;
  published_at: string | null;
  published_by: string | null;
  change_summary: string | null;
  created_at: string;
};

export type MessageTemplateRow = {
  id: string;
  tenant_id: string;
  name: string;
  audience_entity: CommRecipientType;
  category: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  versions?: MessageTemplateVersionRow[];
  latest_version?: MessageTemplateVersionRow | null;
  version_count?: number;
};

export type TemplatePlaceholderRow = {
  id: string;
  entity: CommRecipientType;
  token: string;
  description: string;
  sample_value: string;
  is_required: boolean;
};

/**
 * Get all message templates for the active tenant, with optional category and audience filtering.
 */
export async function getTemplates(filters?: {
  category?: string | null;
  audience?: string | null;
  search?: string | null;
}): Promise<MessageTemplateRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  let query = client
    .from('message_template')
    .select(`
      id,
      tenant_id,
      name,
      audience_entity,
      category,
      description,
      is_active,
      created_at,
      updated_at,
      message_template_version (
        id,
        template_id,
        version_no,
        message_class,
        body_en,
        body_ur,
        sms_encoding,
        is_published,
        published_at,
        published_by,
        change_summary,
        created_at
      )
    `)
    .neq('name', '')
    .order('created_at', { ascending: false });

  if (filters?.category && filters.category !== 'all') {
    query = query.eq('category', filters.category);
  }

  if (filters?.audience && filters.audience !== 'all') {
    query = query.eq('audience_entity', filters.audience);
  }

  const { data, error } = await query;

  if (error) {
    console.error('getTemplates error:', error);
    return [];
  }

  type RawTemplate = Omit<MessageTemplateRow, 'versions' | 'latest_version' | 'version_count'> & {
    message_template_version?: MessageTemplateVersionRow[];
  };

  const rawRows = (data || []) as unknown as RawTemplate[];

  let result: MessageTemplateRow[] = rawRows.map((t) => {
    const rawVersions = (t.message_template_version || []) as MessageTemplateVersionRow[];
    const sortedVersions = [...rawVersions].sort((a, b) => b.version_no - a.version_no);
    const publishedVersion = sortedVersions.find((v) => v.is_published);
    const latestVersion = publishedVersion || sortedVersions[0] || null;

    return {
      id: t.id,
      tenant_id: t.tenant_id,
      name: t.name || 'Untitled Template',
      audience_entity: t.audience_entity,
      category: t.category,
      description: t.description,
      is_active: t.is_active,
      created_at: t.created_at,
      updated_at: t.updated_at,
      versions: sortedVersions,
      latest_version: latestVersion,
      version_count: sortedVersions.length,
    };
  });

  if (filters?.search && filters.search.trim()) {
    const term = filters.search.trim().toLowerCase();
    result = result.filter(
      (t) =>
        t.name.toLowerCase().includes(term) ||
        (t.description && t.description.toLowerCase().includes(term)) ||
        (t.latest_version &&
          (t.latest_version.body_en.toLowerCase().includes(term) ||
            (t.latest_version.body_ur && t.latest_version.body_ur.toLowerCase().includes(term))))
    );
  }

  return result;
}

/**
 * Fetch a single template along with its full version history.
 */
export async function getTemplateDetails(templateId: string): Promise<{
  template: MessageTemplateRow | null;
  versions: MessageTemplateVersionRow[];
  placeholders: TemplatePlaceholderRow[];
}> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data: tmpl, error: tmplError } = await client
    .from('message_template')
    .select('*')
    .eq('id', templateId)
    .single();

  if (tmplError || !tmpl) {
    return { template: null, versions: [], placeholders: [] };
  }

  const { data: versions } = await client
    .from('message_template_version')
    .select('*')
    .eq('template_id', templateId)
    .order('version_no', { ascending: false });

  const { data: placeholders } = await client
    .from('template_placeholder')
    .select('*')
    .eq('entity', tmpl.audience_entity)
    .order('is_required', { ascending: false });

  return {
    template: tmpl as MessageTemplateRow,
    versions: (versions || []) as MessageTemplateVersionRow[],
    placeholders: (placeholders || []) as TemplatePlaceholderRow[],
  };
}

/**
 * Fetch available placeholder tokens for a given recipient entity.
 */
export async function getPlaceholders(entity?: CommRecipientType): Promise<TemplatePlaceholderRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  let query = client.from('template_placeholder').select('*').order('token');
  if (entity) {
    query = query.eq('entity', entity);
  }

  const { data, error } = await query;
  if (error) {
    console.error('getPlaceholders error:', error);
    return [];
  }

  return (data || []) as TemplatePlaceholderRow[];
}

/**
 * Create a new message template with an initial draft or published version.
 */
export async function createTemplate(input: {
  name: string;
  audience_entity: CommRecipientType;
  category: string;
  description?: string;
  body_en: string;
  body_ur?: string;
  sms_encoding?: SmsEncoding;
  message_class?: MessageClass;
  publish_immediately?: boolean;
}): Promise<{ success: boolean; templateId?: string; versionId?: string; error?: string }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  // 1. Get current tenant
  const { data: userData } = await client.auth.getUser();
  if (!userData?.user) {
    return { success: false, error: 'Unauthorized: please log in' };
  }

  // Retrieve user's tenant from app_user
  const { data: appUser } = await client
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', userData.user.id)
    .maybeSingle();

  let tenantId = appUser?.tenant_id;
  if (!tenantId) {
    const { data: campus } = await client.from('campus').select('tenant_id').limit(1).maybeSingle();
    tenantId = campus?.tenant_id;
  }

  if (!tenantId) {
    return { success: false, error: 'Tenant context could not be resolved' };
  }

  // 2. Insert message_template
  const { data: newTmpl, error: tmplErr } = await client
    .from('message_template')
    .insert({
      tenant_id: tenantId,
      name: input.name.trim(),
      audience_entity: input.audience_entity,
      category: input.category || 'general',
      description: input.description?.trim() || null,
      is_active: true,
    })
    .select('id')
    .single();

  if (tmplErr || !newTmpl) {
    return { success: false, error: tmplErr?.message || 'Failed to create template record' };
  }

  // 3. Insert initial version (v1)
  const { data: newVer, error: verErr } = await client
    .from('message_template_version')
    .insert({
      template_id: newTmpl.id,
      version_no: 1,
      message_class: input.message_class || 'transactional',
      body_en: input.body_en.trim(),
      body_ur: input.body_ur?.trim() || null,
      sms_encoding: input.sms_encoding || 'auto',
      is_published: false,
      change_summary: 'Initial draft',
    })
    .select('id')
    .single();

  if (verErr || !newVer) {
    return { success: false, error: verErr?.message || 'Failed to create template version 1' };
  }

  // 4. If publish_immediately, validate and publish
  if (input.publish_immediately) {
    const { error: pubErr } = await client.rpc('publish_template_version', {
      p_version_id: newVer.id,
    });
    if (pubErr) {
      return {
        success: true,
        templateId: newTmpl.id,
        versionId: newVer.id,
        error: `Created as draft, but publish failed: ${pubErr.message}`,
      };
    }
  }

  revalidatePath('/communication/templates');
  return { success: true, templateId: newTmpl.id, versionId: newVer.id };
}

/**
 * Create a new draft version for an existing template.
 */
export async function createNextVersion(input: {
  template_id: string;
  body_en: string;
  body_ur?: string;
  sms_encoding?: SmsEncoding;
  message_class?: MessageClass;
  change_summary?: string;
  publish_immediately?: boolean;
}): Promise<{ success: boolean; versionId?: string; error?: string }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  // Find highest version_no
  const { data: versions } = await client
    .from('message_template_version')
    .select('version_no')
    .eq('template_id', input.template_id)
    .order('version_no', { ascending: false })
    .limit(1);

  const nextVerNo = (versions?.[0]?.version_no || 0) + 1;

  const { data: newVer, error: verErr } = await client
    .from('message_template_version')
    .insert({
      template_id: input.template_id,
      version_no: nextVerNo,
      message_class: input.message_class || 'transactional',
      body_en: input.body_en.trim(),
      body_ur: input.body_ur?.trim() || null,
      sms_encoding: input.sms_encoding || 'auto',
      is_published: false,
      change_summary: input.change_summary?.trim() || `Version ${nextVerNo}`,
    })
    .select('id')
    .single();

  if (verErr || !newVer) {
    return { success: false, error: verErr?.message || 'Failed to create new version' };
  }

  if (input.publish_immediately) {
    const { error: pubErr } = await client.rpc('publish_template_version', {
      p_version_id: newVer.id,
    });
    if (pubErr) {
      return {
        success: true,
        versionId: newVer.id,
        error: `Draft version ${nextVerNo} created, but publish failed: ${pubErr.message}`,
      };
    }
  }

  revalidatePath('/communication/templates');
  return { success: true, versionId: newVer.id };
}

/**
 * Publish a draft template version (enforces token whitelist validation via database RPC).
 */
export async function publishTemplateVersion(versionId: string): Promise<{ success: boolean; error?: string }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { error } = await client.rpc('publish_template_version', {
    p_version_id: versionId,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/templates');
  return { success: true };
}

/**
 * Validate placeholder tokens against the declared whitelist without publishing.
 */
export async function validateVersionTokens(versionId: string): Promise<{ valid: boolean; invalidTokens: string[] }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data, error } = await client.rpc('validate_template_tokens', {
    p_version_id: versionId,
  });

  if (error) {
    console.error('validate_template_tokens error:', error);
    return { valid: false, invalidTokens: [] };
  }

  const invalidTokens = (data || []) as string[];
  return {
    valid: invalidTokens.length === 0,
    invalidTokens,
  };
}

/**
 * Render a template version with sample context values (for live preview).
 */
export async function previewRender(
  versionId: string,
  context: Record<string, string>,
  lang: 'en' | 'ur' = 'en'
): Promise<{ success: boolean; renderedText?: string; error?: string }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data, error } = await client.rpc('render_template', {
    p_version_id: versionId,
    p_ctx: context,
    p_lang: lang,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  return { success: true, renderedText: String(data) };
}
