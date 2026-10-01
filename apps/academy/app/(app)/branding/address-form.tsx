'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { saveCampusAddress } from './address-actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Label } from '@/components/ui/label';

type CampusAddress = { id: string; name: string; addressEn: string; addressUr: string };

function CampusAddressRow({ campus }: { campus: CampusAddress }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [en, setEn] = useState(campus.addressEn);
  const [ur, setUr] = useState(campus.addressUr);
  const save = () =>
    startTransition(async () => {
      const r = await saveCampusAddress({ campusId: campus.id, addressEn: en, addressUr: ur });
      setError(r.error);
      if (!r.error) {
        toast.success(`Address saved for ${campus.name}.`);
        router.refresh();
      }
    });
  return (
    <div className="space-y-2 border-b pb-4" data-testid="address-row">
      <p className="font-medium">{campus.name}</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor={`en-${campus.id}`}>Address (English)</Label>
          <textarea id={`en-${campus.id}`} rows={2} maxLength={300} value={en} onChange={(e) => setEn(e.target.value)} className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
        </div>
        <div className="space-y-1">
          <Label htmlFor={`ur-${campus.id}`}>Address (Urdu)</Label>
          <textarea id={`ur-${campus.id}`} rows={2} maxLength={300} dir="rtl" value={ur} onChange={(e) => setUr(e.target.value)} className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
        </div>
      </div>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
      <Button type="button" size="sm" disabled={pending} onClick={save} data-testid="save-address">
        Save address
      </Button>
    </div>
  );
}

export function AddressForm({ campuses }: { campuses: CampusAddress[] }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Campus addresses on printed reports</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4 text-sm">
        <p className="text-muted-foreground">FR-S09 — printed under the school name on every PDF report. A campus with no letterhead prints the logo instead.</p>
        {campuses.map((c) => (
          <CampusAddressRow key={c.id} campus={c} />
        ))}
      </CardContent>
    </Card>
  );
}
