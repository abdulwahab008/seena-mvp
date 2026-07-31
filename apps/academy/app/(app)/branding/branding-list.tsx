'use client';

import { useRef, useState, useTransition } from 'react';
import { toast } from 'sonner';
import { uploadBrandingAsset, setTenantTheme, getBrandingAssetSignedUrl } from './actions';
import { BRANDING_ASSET_TYPES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type AssetRow = {
  id: string;
  assetType: string;
  campusId: string | null;
  version: number;
  widthPx: number;
  heightPx: number;
};

export type CampusOption = { id: string; name: string };

function measureImage(file: File): Promise<{ width: number; height: number }> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve({ width: img.naturalWidth, height: img.naturalHeight });
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error('Could not read image dimensions.'));
    };
    img.src = url;
  });
}

function UploadForm({ campuses }: { campuses: CampusOption[] }) {
  const [pending, startTransition] = useTransition();
  const [assetType, setAssetType] = useState<(typeof BRANDING_ASSET_TYPES)[number]>('logo');
  const [campusId, setCampusId] = useState<string>('tenant');
  const inputRef = useRef<HTMLInputElement | null>(null);

  const onSubmit = (formData: FormData) => {
    const file = formData.get('file') as File | null;
    if (!file || file.size === 0) {
      toast.error('Choose a file to upload.');
      return;
    }

    startTransition(async () => {
      let dimensions: { width: number; height: number };
      try {
        dimensions = await measureImage(file);
      } catch {
        toast.error('Could not read this image — choose a different file.');
        return;
      }

      formData.set('assetType', assetType);
      formData.set('widthPx', String(dimensions.width));
      formData.set('heightPx', String(dimensions.height));
      if (campusId !== 'tenant') formData.set('campusId', campusId);

      const result = await uploadBrandingAsset({ error: null }, formData);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Branding asset uploaded.');
        if (inputRef.current) inputRef.current.value = '';
      }
    });
  };

  return (
    <form action={onSubmit} className="flex flex-wrap items-end gap-2" data-testid="branding-upload-form">
      <div className="space-y-1">
        <Label>Asset type</Label>
        <Select value={assetType} onValueChange={(v) => setAssetType(v as (typeof BRANDING_ASSET_TYPES)[number])}>
          <SelectTrigger className="h-9 w-36" data-testid="branding-asset-type-trigger">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {BRANDING_ASSET_TYPES.map((t) => (
              <SelectItem key={t} value={t}>
                {t}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="space-y-1">
        <Label>Scope</Label>
        <Select value={campusId} onValueChange={setCampusId}>
          <SelectTrigger className="h-9 w-44" data-testid="branding-campus-trigger">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="tenant">Tenant-wide</SelectItem>
            {campuses.map((c) => (
              <SelectItem key={c.id} value={c.id}>
                {c.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <input ref={inputRef} name="file" type="file" accept="image/jpeg,image/png" className="h-9 text-xs" data-testid="branding-file-input" />
      <Button type="submit" size="sm" disabled={pending} data-testid="branding-upload-submit">
        {pending ? 'Uploading…' : 'Upload'}
      </Button>
    </form>
  );
}

function AssetPreviewLink({ assetId }: { assetId: string }) {
  const [pending, startTransition] = useTransition();
  const [url, setUrl] = useState<string | null>(null);

  const onPreview = () => {
    startTransition(async () => {
      const result = await getBrandingAssetSignedUrl(assetId);
      if (result.error) toast.error(result.error);
      else setUrl(result.url);
    });
  };

  if (url) {
    return (
      <a href={url} target="_blank" rel="noreferrer" className="text-blue-600 underline" data-testid={`branding-preview-link-${assetId}`}>
        Open
      </a>
    );
  }

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onPreview} data-testid={`branding-preview-${assetId}`}>
      Preview
    </Button>
  );
}

function ThemeForm({ primaryHex, secondaryHex }: { primaryHex: string | null; secondaryHex: string | null }) {
  const [pending, startTransition] = useTransition();
  const [primary, setPrimary] = useState(primaryHex ?? '');
  const [secondary, setSecondary] = useState(secondaryHex ?? '');

  const onSubmit = () => {
    const fd = new FormData();
    fd.set('primaryHex', primary);
    fd.set('secondaryHex', secondary);
    startTransition(async () => {
      const result = await setTenantTheme({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Theme saved.');
    });
  };

  return (
    <div className="flex flex-wrap items-end gap-2" data-testid="tenant-theme-form">
      <div className="space-y-1">
        <Label htmlFor="theme-primary">Primary colour</Label>
        <Input id="theme-primary" placeholder="#112233" className="h-9 w-28" value={primary} onChange={(e) => setPrimary(e.target.value)} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="theme-secondary">Secondary colour</Label>
        <Input id="theme-secondary" placeholder="#445566" className="h-9 w-28" value={secondary} onChange={(e) => setSecondary(e.target.value)} />
      </div>
      <Button type="button" size="sm" disabled={pending} onClick={onSubmit} data-testid="theme-save">
        Save theme
      </Button>
    </div>
  );
}

export function BrandingList({
  assets,
  campuses,
  primaryHex,
  secondaryHex,
}: {
  assets: AssetRow[];
  campuses: CampusOption[];
  primaryHex: string | null;
  secondaryHex: string | null;
}) {
  const campusById = new Map(campuses.map((c) => [c.id, c.name]));

  return (
    <div className="space-y-6">
      <Card>
        <CardContent className="space-y-3 p-4">
          <h2 className="font-medium">Upload branding asset</h2>
          <UploadForm campuses={campuses} />
        </CardContent>
      </Card>

      <Card>
        <CardContent className="space-y-3 p-4">
          <h2 className="font-medium">Theme colours</h2>
          <ThemeForm primaryHex={primaryHex} secondaryHex={secondaryHex} />
        </CardContent>
      </Card>

      <div className="space-y-2">
        {assets.length === 0 ? (
          <p className="text-sm text-muted-foreground">No branding assets yet.</p>
        ) : (
          assets.map((a) => (
            <Card key={a.id} data-testid={`branding-asset-row-${a.id}`}>
              <CardContent className="flex items-center justify-between p-4 text-sm">
                <div>
                  <p className="font-medium">
                    {a.assetType} · {a.campusId ? campusById.get(a.campusId) : 'Tenant-wide'}
                  </p>
                  <p className="text-muted-foreground">
                    v{a.version} · {a.widthPx}×{a.heightPx}px
                  </p>
                </div>
                <AssetPreviewLink assetId={a.id} />
              </CardContent>
            </Card>
          ))
        )}
      </div>
    </div>
  );
}
