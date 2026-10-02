'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { supabaseBrowser } from '@/lib/supabase/client';
import { sniffMime } from '@/lib/uploads/sniff';
import { Button } from '@/components/ui/button';
import { addDocument } from './actions';

const CONTROL = 'h-9 w-full rounded-md border bg-background px-2 text-sm';

/**
 * Records a vehicle document and, optionally, uploads the scan to the private
 * transport-documents bucket first (path tenant_id/vehicle_id/file).
 */
export function DocumentForm({ tenantId, vehicles }: { tenantId: string; vehicles: { id: string; label: string }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const onSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const form = e.currentTarget;
    const fd = new FormData(form);
    const file = (fd.get('file') as File | null) && (fd.get('file') as File).size > 0 ? (fd.get('file') as File) : null;
    const vehicleId = String(fd.get('vehicleId') ?? '');
    startTransition(async () => {
      let filePath = '';
      if (file) {
        const bytes = new Uint8Array(await file.slice(0, 16).arrayBuffer());
        const mime = sniffMime(bytes);
        if (!mime) {
          setError('Upload a PDF, JPEG, PNG or WebP file.');
          return;
        }
        if (file.size > 5 * 1024 * 1024) {
          setError('The file must be 5 MB or smaller.');
          return;
        }
        filePath = `${tenantId}/${vehicleId}/${crypto.randomUUID()}-${file.name.replace(/[^\w.-]/g, '_')}`;
        const { error: upErr } = await supabaseBrowser().storage.from('transport-documents').upload(filePath, file, { contentType: mime });
        if (upErr) {
          setError('The file could not be uploaded.');
          return;
        }
      }
      const r = await addDocument({
        vehicleId,
        docType: String(fd.get('docType') ?? ''),
        docNo: String(fd.get('docNo') ?? ''),
        issuedOn: String(fd.get('issuedOn') ?? ''),
        expiresOn: String(fd.get('expiresOn') ?? ''),
        filePath,
        mandatory: String(fd.get('mandatory') === 'on'),
      });
      setError(r.error);
      if (!r.error) {
        toast.success('Document recorded.');
        form.reset();
        router.refresh();
      }
    });
  };

  return (
    <form onSubmit={onSubmit} className="space-y-3" data-testid="document-form" noValidate>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Vehicle *</span>
          <select name="vehicleId" className={CONTROL} defaultValue="">
            <option value="">Select</option>
            {vehicles.map((v) => (
              <option key={v.id} value={v.id}>
                {v.label}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Document *</span>
          <select name="docType" className={CONTROL} defaultValue="fitness">
            <option value="fitness">Fitness certificate</option>
            <option value="token_tax">Token tax</option>
            <option value="insurance">Insurance</option>
            <option value="permit">Route permit</option>
          </select>
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Document no.</span>
          <input name="docNo" className={CONTROL} />
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Issued on</span>
          <input type="date" name="issuedOn" className={CONTROL} />
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Expires on *</span>
          <input type="date" name="expiresOn" className={CONTROL} />
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Scan (PDF or image, optional)</span>
          <input type="file" name="file" accept="application/pdf,image/jpeg,image/png,image/webp" className="block text-sm" />
        </label>
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" name="mandatory" defaultChecked /> Enforced (blocks assignment when expired)
        </label>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="document-form-error">
          {error}
        </p>
      )}
      <Button type="submit" size="sm" disabled={pending} data-testid="document-form-submit">
        Record document
      </Button>
    </form>
  );
}
