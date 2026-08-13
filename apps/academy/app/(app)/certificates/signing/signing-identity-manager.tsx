'use client';

import { useRef, useState, useTransition } from 'react';
import { toast } from 'sonner';
import { createSigningIdentity, retireSigningIdentity } from './actions';
import { SEAL_REQUIRED_DPI, SIGNING_IDENTITY_MIN_WIDTH_PX } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type CampusOption = { id: string; name: string; code: string };

export type IdentityRow = {
  id: string;
  campusId: string;
  holderName: string;
  designation: string;
  validFrom: string;
  validTo: string | null;
  signatureWidthPx: number;
  stampWidthPx: number | null;
  issuedCount: number;
};

/**
 * FR-T09. The pixel dimensions are measured in the browser, exactly as
 * FR-A18's branding upload does it — the server cannot decode an image
 * without a dependency this repo does not have, and create_signing_identity()
 * is what actually refuses an inadequate one.
 */
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

function IdentityForm({ campuses }: { campuses: CampusOption[] }) {
  const [pending, startTransition] = useTransition();
  const [campusId, setCampusId] = useState<string>(campuses[0]?.id ?? '');
  const formRef = useRef<HTMLFormElement | null>(null);

  const onSubmit = (formData: FormData) => {
    const signature = formData.get('signature');
    if (!(signature instanceof File) || signature.size === 0) {
      toast.error('Choose a signature image.');
      return;
    }
    const stampEntry = formData.get('stamp');
    const stamp = stampEntry instanceof File && stampEntry.size > 0 ? stampEntry : null;

    startTransition(async () => {
      try {
        const signatureSize = await measureImage(signature);
        formData.set('signatureWidthPx', String(signatureSize.width));
        formData.set('signatureHeightPx', String(signatureSize.height));
        if (stamp) {
          const stampSize = await measureImage(stamp);
          formData.set('stampWidthPx', String(stampSize.width));
          formData.set('stampHeightPx', String(stampSize.height));
        }
      } catch {
        toast.error('Could not read that image — choose a different file.');
        return;
      }

      formData.set('campusId', campusId);
      const result = await createSigningIdentity({ error: null }, formData);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${result.holderName} now signs certificates at this campus.`);
        formRef.current?.reset();
      }
    });
  };

  return (
    <form ref={formRef} action={onSubmit} className="space-y-3" data-testid="signing-identity-form">
      <div className="flex flex-wrap items-end gap-2">
        <div className="space-y-1">
          <Label>Campus</Label>
          <Select value={campusId} onValueChange={setCampusId}>
            <SelectTrigger className="h-9 w-48" data-testid="signing-campus-trigger">
              <SelectValue placeholder="Choose a campus" />
            </SelectTrigger>
            <SelectContent>
              {campuses.map((c) => (
                <SelectItem key={c.id} value={c.id} data-testid={`signing-campus-${c.code}`}>
                  {c.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="signing-holder">Signatory</Label>
          <Input id="signing-holder" name="holderName" className="h-9 w-52" placeholder="Farhat Jabeen" data-testid="signing-holder-name" />
        </div>
        <div className="space-y-1">
          <Label htmlFor="signing-designation">Designation</Label>
          <Input id="signing-designation" name="designation" className="h-9 w-44" placeholder="Principal" data-testid="signing-designation" />
        </div>
        <div className="space-y-1">
          <Label htmlFor="signing-valid-from">Valid from</Label>
          <Input id="signing-valid-from" name="validFrom" type="date" className="h-9 w-40" data-testid="signing-valid-from" />
        </div>
      </div>

      <div className="flex flex-wrap items-end gap-4">
        <div className="space-y-1">
          <Label htmlFor="signing-signature-file">Signature image</Label>
          <input
            id="signing-signature-file"
            name="signature"
            type="file"
            accept="image/jpeg,image/png"
            className="h-9 text-xs"
            data-testid="signing-signature-input"
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="signing-stamp-file">School stamp (optional)</Label>
          <input
            id="signing-stamp-file"
            name="stamp"
            type="file"
            accept="image/jpeg,image/png"
            className="h-9 text-xs"
            data-testid="signing-stamp-input"
          />
        </div>
        <Button type="submit" size="sm" disabled={pending || !campusId} data-testid="signing-submit">
          {pending ? 'Saving…' : 'Set signing identity'}
        </Button>
      </div>

      <p className="text-xs text-muted-foreground">
        Printed at {SEAL_REQUIRED_DPI} DPI: a signature needs at least {SIGNING_IDENTITY_MIN_WIDTH_PX.signature}px across and a stamp{' '}
        {SIGNING_IDENTITY_MIN_WIDTH_PX.stamp}px. Setting a new signatory closes the previous one — certificates already issued keep
        the signature they were issued with.
      </p>
    </form>
  );
}

function RetireButton({ identityId }: { identityId: string }) {
  const [pending, startTransition] = useTransition();

  const onRetire = () => {
    const fd = new FormData();
    fd.set('identityId', identityId);
    startTransition(async () => {
      const result = await retireSigningIdentity({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Signing identity closed.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onRetire} data-testid={`signing-retire-${identityId}`}>
      {pending ? 'Closing…' : 'Close'}
    </Button>
  );
}

export function SigningIdentityManager({ campuses, identities }: { campuses: CampusOption[]; identities: IdentityRow[] }) {
  const campusById = new Map(campuses.map((c) => [c.id, c.name]));

  return (
    <div className="space-y-6">
      <Card>
        <CardContent className="space-y-3 p-4">
          <h2 className="font-medium">Set who signs</h2>
          <IdentityForm campuses={campuses} />
        </CardContent>
      </Card>

      <div className="space-y-2">
        {identities.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="signing-identities-empty">
            No signing identity yet — certificates are signed in the name of whoever issues them.
          </p>
        ) : (
          identities.map((i) => (
            <Card key={i.id} data-testid={`signing-identity-row-${i.id}`}>
              <CardContent className="flex items-center justify-between p-4 text-sm">
                <div>
                  <p className="font-medium">
                    {i.holderName} · {i.designation}
                    {i.validTo ? (
                      <span className="ml-2 text-xs text-muted-foreground" data-testid={`signing-identity-closed-${i.id}`}>
                        closed {i.validTo}
                      </span>
                    ) : (
                      <span className="ml-2 text-xs text-green-700" data-testid={`signing-identity-current-${i.id}`}>
                        current
                      </span>
                    )}
                  </p>
                  <p className="text-muted-foreground">
                    {campusById.get(i.campusId) ?? 'Campus'} · from {i.validFrom} · signature {i.signatureWidthPx}px
                    {i.stampWidthPx ? ` · stamp ${i.stampWidthPx}px` : ' · no stamp'} · {i.issuedCount} certificate
                    {i.issuedCount === 1 ? '' : 's'} signed
                  </p>
                </div>
                {i.validTo ? null : <RetireButton identityId={i.id} />}
              </CardContent>
            </Card>
          ))
        )}
      </div>
    </div>
  );
}
