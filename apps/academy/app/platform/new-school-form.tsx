'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { provisionSchool, type ProvisionState } from './actions';
import { InviteLinkPanel } from '@/app/(app)/staff/invite-link-panel';
import { provisionTenantSchema, type ProvisionTenantInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

type FormValues = ProvisionTenantInput;

export function NewSchoolForm() {
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<(ProvisionState & { ownerEmail: string }) | null>(null);
  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<FormValues>({ resolver: zodResolver(provisionTenantSchema) });

  const onSubmit = handleSubmit((values) => {
    setResult(null);
    const fd = new FormData();
    fd.set('slug', values.slug);
    fd.set('legalName', values.legalName);
    fd.set('ownerEmail', values.ownerEmail);
    startTransition(async () => {
      const r = await provisionSchool({ error: null, tenantId: null }, fd);
      setResult({ ...r, ownerEmail: values.ownerEmail });
      if (r.tenantId) {
        toast.success('School created.');
        reset();
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor="slug">School code</Label>
        <Input id="slug" placeholder="beaconhouse-gulberg" {...register('slug')} />
        {errors.slug && <p className="text-sm text-destructive">{errors.slug.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="legalName">Legal / school group name</Label>
        <Input id="legalName" placeholder="Beaconhouse Gulberg Campus" {...register('legalName')} />
        {errors.legalName && <p className="text-sm text-destructive">{errors.legalName.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="ownerEmail">Owner email</Label>
        <Input id="ownerEmail" type="email" placeholder="owner@school.edu.pk" {...register('ownerEmail')} />
        {errors.ownerEmail && <p className="text-sm text-destructive">{errors.ownerEmail.message}</p>}
      </div>
      {result?.error && (
        <p role="alert" className="text-sm text-destructive">
          {result.error}
        </p>
      )}
      {result?.tenantId && (
        <div className="space-y-2" data-testid="provision-result">
          <p className="text-sm text-foreground">
            School created. Send the owner this link to join:
          </p>
          {result.delivery && <InviteLinkPanel email={result.ownerEmail} delivery={result.delivery} />}
        </div>
      )}
      <Button type="submit" disabled={pending}>
        {pending ? 'Creating…' : 'Create school'}
      </Button>
    </form>
  );
}
