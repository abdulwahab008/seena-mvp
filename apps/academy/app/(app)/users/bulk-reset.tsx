'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { resetSectionPasswords, type ResetSlip } from './bulk-reset-actions';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
const schema = z.object({ sectionId: z.string().min(1, 'Choose a section') });

export function BulkPasswordReset({ sections }: { sections: { id: string; label: string }[] }) {
  const [pending, startTransition] = useTransition();
  const [confirming, setConfirming] = useState(false);
  const [slips, setSlips] = useState<ResetSlip[] | null>(null);
  const { register, handleSubmit, getValues, formState: { errors } } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: { sectionId: '' } });
  const run = () =>
    startTransition(async () => {
      const r = await resetSectionPasswords(getValues('sectionId'));
      setConfirming(false);
      if (r.error) return void toast.error(r.error);
      setSlips(r.slips ?? []);
      toast.success(`Reset ${r.slips?.length ?? 0} student passwords. Print the slips now; they are not shown again.`);
    });
  return (
    <Card className="mt-6 print:mt-0 print:border-0 print:shadow-none">
      <CardHeader className="print:hidden">
        <CardTitle className="text-base">Reset a class&apos;s student passwords</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <form onSubmit={handleSubmit(() => setConfirming(true))} className="flex flex-wrap items-end gap-2 print:hidden" noValidate>
          <div className="min-w-56 space-y-1">
            <Label htmlFor="br-section">Section</Label>
            <select id="br-section" className={SELECT} {...register('sectionId')}>
              <option value="">Choose…</option>
              {sections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
            {errors.sectionId && <p className="text-sm text-destructive">{errors.sectionId.message}</p>}
          </div>
          <Button type="submit" variant="outline" disabled={pending}>
            Reset passwords
          </Button>
        </form>
        {slips && slips.length > 0 && (
          <div className="space-y-2">
            <Button variant="outline" className="print:hidden" onClick={() => window.print()}>
              Print slips
            </Button>
            <div className="grid gap-2 sm:grid-cols-2 print:grid-cols-2" data-testid="reset-slips">
              {slips.map((s) => (
                <div key={s.grNumber} className="rounded-md border border-dashed p-3 text-sm" data-testid="reset-slip">
                  <p className="font-medium">{s.name}</p>
                  <p>Sign in with GR number: {s.grNumber}</p>
                  <p>
                    Temporary password: <span className="font-mono">{s.password}</span>
                  </p>
                  <p className="text-xs text-muted-foreground">You will choose your own password after signing in.</p>
                </div>
              ))}
            </div>
          </div>
        )}
        <Modal
          open={confirming}
          onClose={() => setConfirming(false)}
          title="Reset every student's password in this section?"
          description="Their current passwords stop working at once. Each student gets a temporary password on a printable slip and must choose a new one at next sign-in."
          size="sm"
          footer={
            <>
              <Button variant="outline" onClick={() => setConfirming(false)} disabled={pending}>
                Cancel
              </Button>
              <Button variant="destructive" onClick={run} disabled={pending}>
                Reset
              </Button>
            </>
          }
        />
      </CardContent>
    </Card>
  );
}
