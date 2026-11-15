'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { saveStudentMedical } from '../actions';
import { DISABILITY_LABEL } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';

export type StudentMedical = {
  allergies: string[];
  conditions: string[];
  medications: string[];
  disability_type: keyof typeof DISABILITY_LABEL;
  has_critical_allergy: boolean;
  emergency_contact_name: string | null;
  emergency_contact_phone: string | null;
};

export function MedicalView({ studentId, medical }: { studentId: string; medical: StudentMedical | null }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const m = medical;
  const rows: [string, string][] = m
    ? [
        ['Allergies', m.allergies.join(', ')],
        ['Conditions', m.conditions.join(', ')],
        ['Medicines', m.medications.join(', ')],
        ['Disability', m.disability_type === 'none' ? '' : DISABILITY_LABEL[m.disability_type]],
        ['Emergency contact', [m.emergency_contact_name, m.emergency_contact_phone].filter(Boolean).join(' · ')],
      ]
    : [];
  const filled = rows.filter(([, v]) => v);

  return (
    <div className="space-y-3" data-testid="student-medical">
      {m?.has_critical_allergy && (
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm font-medium text-destructive">Critical allergy</p>
      )}
      {filled.length > 0 ? (
        <dl className="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
          {filled.map(([label, value]) => (
            <div key={label}>
              <dt className="text-xs text-muted-foreground">{label}</dt>
              <dd>{value}</dd>
            </div>
          ))}
        </dl>
      ) : (
        <p className="text-sm text-muted-foreground">No medical details recorded.</p>
      )}
      <Button variant="outline" size="sm" onClick={() => setOpen(true)} data-testid="edit-medical">
        {m ? 'Edit medical details' : 'Add medical details'}
      </Button>
      {open && (
        <Modal open={open} onClose={() => setOpen(false)} title="Medical details" description="Separate several items with commas. Only the principal, owner and nurse can see these.">
          <form
            className="grid gap-3 sm:grid-cols-2"
            onSubmit={(e) => {
              e.preventDefault();
              const fd = new FormData(e.currentTarget);
              startTransition(async () => {
                const r = await saveStudentMedical(studentId, fd);
                if (r.error) setError(r.error);
                else {
                  toast.success('Medical details saved.');
                  setOpen(false);
                  router.refresh();
                }
              });
            }}
          >
            {(
              [
                ['allergies', 'Allergies', m?.allergies],
                ['conditions', 'Conditions', m?.conditions],
                ['medications', 'Medicines', m?.medications],
              ] as const
            ).map(([name, label, value]) => (
              <div key={name} className="space-y-1 sm:col-span-2">
                <Label htmlFor={`medical-${name}`}>{label}</Label>
                <Input id={`medical-${name}`} name={name} defaultValue={value?.join(', ') ?? ''} maxLength={500} />
              </div>
            ))}
            <div className="space-y-1">
              <Label htmlFor="medical-disability">Disability</Label>
              <select
                id="medical-disability"
                name="disabilityType"
                defaultValue={m?.disability_type ?? 'none'}
                className="h-10 w-full rounded-md border bg-background px-3 text-sm"
              >
                {Object.entries(DISABILITY_LABEL).map(([v, label]) => (
                  <option key={v} value={v}>
                    {label}
                  </option>
                ))}
              </select>
            </div>
            <label className="flex items-center gap-2 self-end pb-2 text-sm">
              <input type="checkbox" name="hasCriticalAllergy" defaultChecked={m?.has_critical_allergy ?? false} className="size-4" />
              Critical allergy
            </label>
            <div className="space-y-1">
              <Label htmlFor="medical-contact-name">Emergency contact name</Label>
              <Input id="medical-contact-name" name="emergencyContactName" defaultValue={m?.emergency_contact_name ?? ''} maxLength={100} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="medical-contact-phone">Emergency contact phone</Label>
              <Input id="medical-contact-phone" name="emergencyContactPhone" type="tel" defaultValue={m?.emergency_contact_phone ?? ''} placeholder="0300-1234567" />
            </div>
            {error && (
              <p role="alert" className="text-sm text-destructive sm:col-span-2">
                {error}
              </p>
            )}
            <div className="flex justify-end gap-2 sm:col-span-2">
              <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={pending}>
                {pending ? 'Saving…' : 'Save'}
              </Button>
            </div>
          </form>
        </Modal>
      )}
    </div>
  );
}
