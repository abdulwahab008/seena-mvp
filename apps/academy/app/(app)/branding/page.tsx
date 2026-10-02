import { supabaseServer } from '@/lib/supabase/server';
import { BrandingList } from './branding-list';
import { AddressForm } from './address-form';

export default async function BrandingPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: assets }, { data: theme }, { data: addresses }] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    supabase
      .from('branding_asset')
      .select('id, asset_type, campus_id, version, width_px, height_px')
      .eq('is_current', true)
      .order('asset_type'),
    supabase.from('tenant_theme').select('primary_hex, secondary_hex').maybeSingle(),
    supabase.from('campus_branding').select('campus_id, address_en, address_ur'),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Branding</h1>
        <p className="text-sm text-muted-foreground">
          FR-A18 — logo, letterhead, signature and stamp per campus, falling back to the tenant-wide asset.
        </p>
      </div>
      <BrandingList
        assets={(assets ?? []).map((a) => ({
          id: a.id,
          assetType: a.asset_type,
          campusId: a.campus_id,
          version: a.version,
          widthPx: a.width_px,
          heightPx: a.height_px,
        }))}
        campuses={(campuses ?? []).map((c) => ({ id: c.id, name: c.name }))}
        primaryHex={theme?.primary_hex ?? null}
        secondaryHex={theme?.secondary_hex ?? null}
      />
      <AddressForm
        campuses={(campuses ?? []).map((c) => ({ id: c.id, name: c.name, addressEn: addresses?.find((a) => a.campus_id === c.id)?.address_en ?? '', addressUr: addresses?.find((a) => a.campus_id === c.id)?.address_ur ?? '' }))}
      />
    </div>
  );
}
