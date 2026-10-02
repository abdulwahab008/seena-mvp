'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { provisionTenant } from './actions';
import { provisionTenantSchema } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const FormSchema = provisionTenantSchema.extend({ setupToken: z.string().min(1, 'Required') });
type FormValues = z.infer<typeof FormSchema>;

export function ProvisionForm() {
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<{ error: string | null; tenantId: string | null } | null>(null);
  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<FormValues>({ resolver: zodResolver(FormSchema) });

  const onSubmit = handleSubmit((values) => {
    setResult(null);
    const fd = new FormData();
    fd.set('slug', values.slug);
    fd.set('legalName', values.legalName);
    fd.set('ownerEmail', values.ownerEmail);
    fd.set('setupToken', values.setupToken);
    startTransition(async () => {
      const r = await provisionTenant({ error: null, tenantId: null }, fd);
      setResult(r);
      if (r.tenantId) {
        toast.success(`Tenant provisioned: ${r.tenantId}`);
        reset();
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor="slug">Slug</Label>
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
      <div className="space-y-2">
        <Label htmlFor="setupToken">Setup token</Label>
        <Input id="setupToken" type="password" {...register('setupToken')} />
        {errors.setupToken && <p className="text-sm text-destructive">{errors.setupToken.message}</p>}
      </div>
      {result?.error && (
        <p role="alert" className="text-sm text-destructive">
          {result.error}
        </p>
      )}
      {result?.tenantId && (
        <p className="text-sm text-foreground">
          Provisioned. Tenant id: <code>{result.tenantId}</code>
        </p>
      )}
      <Button type="submit" disabled={pending}>
        {pending ? 'Provisioning…' : 'Provision tenant'}
      </Button>
    </form>
  );
}
