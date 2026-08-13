'use server';

import { revalidatePath } from 'next/cache';
import {
  ALLOWED_BRANDING_MIME_TYPES,
  MAX_BRANDING_FILE_SIZE,
  SIGNING_IDENTITY_MIN_WIDTH_PX,
  createSigningIdentitySchema,
  retireSigningIdentitySchema,
} from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

/**
 * FR-T09: who signs a certificate, and with which image.
 *
 * The upload is FR-A18's reserve → upload → confirm, unchanged and
 * deliberately not reimplemented: a signature IS a branding asset, it lives
 * in the same private bucket under the same versioning, and that versioning
 * is what keeps a superseded Principal's signature on disk for the
 * certificates that were issued with it. What FR-T09 adds around it is the
 * identity row that says whose signature it is, and the 300-DPI floor —
 * enforced by create_signing_identity(), mirrored here only to say something
 * useful when it refuses.
 *
 * Both the RPC and the storage policy admit Owner and Super Admin only
 * (AC4). This action does not re-check the role: the database is what
 * enforces it, and a duplicated gate is one that eventually disagrees.
 */

const PATH = '/certificates/signing';

export type SigningIdentityState = { error: string | null; holderName?: string };

type ReservedAsset = { assetId: string; storagePath: string };

async function uploadAsset(
  supabase: Awaited<ReturnType<typeof supabaseServer>>,
  file: File,
  assetType: 'signature' | 'stamp',
  campusId: string,
  widthPx: number,
  heightPx: number,
): Promise<{ error: string | null; asset?: ReservedAsset }> {
  if (file.size > MAX_BRANDING_FILE_SIZE) return { error: 'Maximum file size 3 MB.' };
  if (!ALLOWED_BRANDING_MIME_TYPES.includes(file.type as (typeof ALLOWED_BRANDING_MIME_TYPES)[number])) {
    return { error: 'Only JPEG and PNG images are accepted.' };
  }

  const ext = file.name.includes('.') ? file.name.split('.').pop()! : 'png';
  const { data, error } = await supabase.rpc('create_branding_asset', {
    p_asset_type: assetType,
    p_width_px: widthPx,
    p_height_px: heightPx,
    p_bytes: file.size,
    p_mime_type: file.type,
    p_file_ext: ext,
    p_campus_id: campusId,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'Only an Owner or Super Admin may upload a signature or a school stamp.' };
    }
    if (error.message.includes('ASSET_TOO_LARGE')) return { error: 'Maximum file size 3 MB.' };
    if (error.message.includes('UNSUPPORTED_FILE_TYPE')) return { error: 'Only JPEG and PNG images are accepted.' };
    return { error: `Could not start the ${assetType} upload.` };
  }

  const asset = data as unknown as { asset_id: string; storage_path: string };
  const { error: uploadError } = await supabase.storage
    .from('branding')
    .upload(asset.storage_path, file, { contentType: file.type, upsert: false });
  if (uploadError) {
    await supabase.rpc('delete_branding_asset', { p_asset_id: asset.asset_id });
    return { error: `The ${assetType} upload failed. Please try again.` };
  }

  // is_current is what resolve_branding() reads and what supersedes the
  // previous version; the identity row points at this exact asset id either
  // way, so an old certificate is unaffected by a later confirm.
  await supabase.rpc('confirm_branding_asset', { p_asset_id: asset.asset_id });
  return { error: null, asset: { assetId: asset.asset_id, storagePath: asset.storage_path } };
}

export async function createSigningIdentity(_prev: SigningIdentityState, formData: FormData): Promise<SigningIdentityState> {
  const signature = formData.get('signature');
  if (!(signature instanceof File) || signature.size === 0) return { error: 'Choose a signature image.' };
  const stampFile = formData.get('stamp');
  const stamp = stampFile instanceof File && stampFile.size > 0 ? stampFile : null;

  const parsed = createSigningIdentitySchema.safeParse({
    campusId: formData.get('campusId'),
    holderName: formData.get('holderName'),
    designation: formData.get('designation'),
    validFrom: formData.get('validFrom') ?? '',
    signatureWidthPx: formData.get('signatureWidthPx'),
    signatureHeightPx: formData.get('signatureHeightPx'),
    stampWidthPx: formData.get('stampWidthPx') || undefined,
    stampHeightPx: formData.get('stampHeightPx') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const input = parsed.data;

  if (input.signatureWidthPx < SIGNING_IDENTITY_MIN_WIDTH_PX.signature) {
    return {
      error: `The signature is ${input.signatureWidthPx}px wide — it needs at least ${SIGNING_IDENTITY_MIN_WIDTH_PX.signature}px to print at 300 DPI. Rescan it larger.`,
    };
  }
  if (stamp && input.stampWidthPx && input.stampWidthPx < SIGNING_IDENTITY_MIN_WIDTH_PX.stamp) {
    return {
      error: `The stamp is ${input.stampWidthPx}px wide — it needs at least ${SIGNING_IDENTITY_MIN_WIDTH_PX.stamp}px to print at 300 DPI.`,
    };
  }

  const supabase = await supabaseServer();

  const signatureUpload = await uploadAsset(
    supabase,
    signature,
    'signature',
    input.campusId,
    input.signatureWidthPx,
    input.signatureHeightPx,
  );
  if (signatureUpload.error || !signatureUpload.asset) return { error: signatureUpload.error ?? 'Could not upload the signature.' };

  let stampAsset: ReservedAsset | undefined;
  if (stamp && input.stampWidthPx && input.stampHeightPx) {
    const stampUpload = await uploadAsset(supabase, stamp, 'stamp', input.campusId, input.stampWidthPx, input.stampHeightPx);
    if (stampUpload.error || !stampUpload.asset) return { error: stampUpload.error ?? 'Could not upload the stamp.' };
    stampAsset = stampUpload.asset;
  }

  const { error } = await supabase.rpc('create_signing_identity', {
    p_campus_id: input.campusId,
    p_holder_name: input.holderName,
    p_designation: input.designation,
    p_signature_asset_id: signatureUpload.asset.assetId,
    p_stamp_asset_id: stampAsset?.assetId,
    p_valid_from: input.validFrom || undefined,
  });
  if (error) {
    if (error.message.includes('SIGNATURE_RESOLUTION_TOO_LOW')) {
      return { error: `The signature is too small to print at 300 DPI — at least ${SIGNING_IDENTITY_MIN_WIDTH_PX.signature}px across is needed.` };
    }
    if (error.message.includes('STAMP_RESOLUTION_TOO_LOW')) {
      return { error: `The stamp is too small to print at 300 DPI — at least ${SIGNING_IDENTITY_MIN_WIDTH_PX.stamp}px across is needed.` };
    }
    if (error.message.includes('SIGNATORY_INCOMPLETE')) return { error: 'A signing identity needs both a name and a designation.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Super Admin may set who signs a certificate.' };
    return { error: 'Could not save the signing identity.' };
  }

  revalidatePath(PATH);
  return { error: null, holderName: input.holderName };
}

export async function retireSigningIdentity(_prev: SigningIdentityState, formData: FormData): Promise<SigningIdentityState> {
  const parsed = retireSigningIdentitySchema.safeParse({
    identityId: formData.get('identityId'),
    validTo: formData.get('validTo') ?? '',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('retire_signing_identity', {
    p_identity_id: parsed.data.identityId,
    p_valid_to: parsed.data.validTo || undefined,
  });
  if (error) {
    if (error.message.includes('ALREADY_RETIRED')) return { error: 'That signing identity has already been closed.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Super Admin may close a signing identity.' };
    return { error: 'Could not close the signing identity.' };
  }

  revalidatePath(PATH);
  return { error: null };
}
