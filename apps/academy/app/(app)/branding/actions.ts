'use server';

import { revalidatePath } from 'next/cache';
import {
  uploadBrandingAssetSchema,
  setTenantThemeSchema,
  MAX_BRANDING_FILE_SIZE,
  ALLOWED_BRANDING_MIME_TYPES,
  BRANDING_MIN_WIDTH_PX,
} from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type UploadBrandingAssetState = { error: string | null };

// FR-A18: reserve → upload → confirm. If the storage upload never
// completes, the reservation is deleted as a compensating action —
// create_branding_asset() never flips is_current itself, so an
// abandoned attempt can't leave resolve_branding() pointing at a
// missing object.
export async function uploadBrandingAsset(_prev: UploadBrandingAssetState, formData: FormData): Promise<UploadBrandingAssetState> {
  const file = formData.get('file');
  if (!(file instanceof File) || file.size === 0) return { error: 'Choose a file to upload.' };

  const parsed = uploadBrandingAssetSchema.safeParse({
    assetType: formData.get('assetType'),
    campusId: formData.get('campusId') || undefined,
    widthPx: formData.get('widthPx'),
    heightPx: formData.get('heightPx'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  if (file.size > MAX_BRANDING_FILE_SIZE) return { error: 'Maximum file size 3 MB.' };
  if (!ALLOWED_BRANDING_MIME_TYPES.includes(file.type as (typeof ALLOWED_BRANDING_MIME_TYPES)[number])) {
    return { error: 'Only JPEG and PNG images are accepted.' };
  }

  const ext = file.name.includes('.') ? file.name.split('.').pop()! : 'bin';
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('create_branding_asset', {
    p_asset_type: parsed.data.assetType,
    p_width_px: parsed.data.widthPx,
    p_height_px: parsed.data.heightPx,
    p_bytes: file.size,
    p_mime_type: file.type,
    p_file_ext: ext,
    p_campus_id: parsed.data.campusId,
  });
  if (error) {
    if (error.message.includes('ASSET_RESOLUTION_TOO_LOW')) {
      return { error: `Image is too small — minimum width for a ${parsed.data.assetType} is ${BRANDING_MIN_WIDTH_PX[parsed.data.assetType]}px.` };
    }
    if (error.message.includes('ASSET_TOO_LARGE')) return { error: 'Maximum file size 3 MB.' };
    if (error.message.includes('UNSUPPORTED_FILE_TYPE')) return { error: 'Only JPEG and PNG images are accepted.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to upload branding assets.' };
    return { error: 'Could not start the upload.' };
  }

  const { asset_id: assetId, storage_path: storagePath } = data as { asset_id: string; storage_path: string };

  const { error: uploadError } = await supabase.storage.from('branding').upload(storagePath, file, { contentType: file.type, upsert: false });
  if (uploadError) {
    await supabase.rpc('delete_branding_asset', { p_asset_id: assetId });
    return { error: 'Upload failed. Please try again.' };
  }

  const { error: confirmError } = await supabase.rpc('confirm_branding_asset', { p_asset_id: assetId });
  if (confirmError) return { error: 'Uploaded, but could not activate the asset.' };

  revalidatePath('/branding');
  return { error: null };
}

export type SetTenantThemeState = { error: string | null };

export async function setTenantTheme(_prev: SetTenantThemeState, formData: FormData): Promise<SetTenantThemeState> {
  const parsed = setTenantThemeSchema.safeParse({
    primaryHex: formData.get('primaryHex') || '',
    secondaryHex: formData.get('secondaryHex') || '',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_tenant_theme', {
    p_primary_hex: parsed.data.primaryHex || undefined,
    p_secondary_hex: parsed.data.secondaryHex || undefined,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to set the tenant theme.' };
    return { error: 'Could not save the theme.' };
  }

  revalidatePath('/branding');
  return { error: null };
}

export async function getBrandingAssetSignedUrl(assetId: string): Promise<{ error: string | null; url: string | null }> {
  const supabase = await supabaseServer();
  const { data: asset, error: fetchError } = await supabase.from('branding_asset').select('storage_path').eq('id', assetId).single();
  if (fetchError || !asset) return { error: 'Asset not found.', url: null };

  const { data, error } = await supabase.storage.from('branding').createSignedUrl(asset.storage_path, 900);
  if (error || !data) return { error: 'Could not generate a preview link.', url: null };
  return { error: null, url: data.signedUrl };
}
