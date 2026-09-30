'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { paymentGatewayConfigSchema, type PaymentGatewayConfigInput } from '@/lib/validation';
import { saveGatewayConfig } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function GatewayForm({ defaults }: { defaults?: Partial<PaymentGatewayConfigInput> }) {
  const [pending, startTransition] = useTransition();
  const [serverError, setServerError] = useState<string | null>(null);
  const form = useForm<PaymentGatewayConfigInput>({
    resolver: zodResolver(paymentGatewayConfigSchema),
    defaultValues: { gateway: 'jazzcash', merchantId: '', secretRef: '', isLive: false, isEnabled: true, ...defaults },
  });

  const onSubmit = form.handleSubmit((values) => {
    setServerError(null);
    startTransition(async () => {
      const result = await saveGatewayConfig(values);
      if (result.error) setServerError(result.error);
      else toast.success('Gateway saved.');
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid gap-4 sm:grid-cols-2" noValidate>
      <div className="space-y-2">
        <Label htmlFor="gateway">Gateway</Label>
        <select id="gateway" className="h-10 w-full rounded-md border bg-background px-3 text-sm" {...form.register('gateway')}>
          <option value="jazzcash">JazzCash</option>
          <option value="easypaisa">EasyPaisa</option>
          <option value="onelink">1LINK</option>
        </select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="merchantId">Merchant ID</Label>
        <Input id="merchantId" {...form.register('merchantId')} />
        {form.formState.errors.merchantId && <p className="text-sm text-destructive">{form.formState.errors.merchantId.message}</p>}
      </div>
      <div className="space-y-2 sm:col-span-2">
        <Label htmlFor="secretRef">Secret environment variable name</Label>
        <Input id="secretRef" placeholder="PAY_SECRET_JAZZCASH" {...form.register('secretRef')} />
        <p className="text-xs text-muted-foreground">The signing secret itself is set in the server environment, never here.</p>
        {form.formState.errors.secretRef && <p className="text-sm text-destructive">{form.formState.errors.secretRef.message}</p>}
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" {...form.register('isEnabled')} /> Enabled
      </label>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" {...form.register('isLive')} /> Live (uncheck for sandbox)
      </label>
      {serverError && (
        <p role="alert" className="text-sm text-destructive sm:col-span-2">
          {serverError}
        </p>
      )}
      <div className="sm:col-span-2">
        <Button type="submit" disabled={pending}>
          {pending ? 'Saving…' : 'Save gateway'}
        </Button>
      </div>
    </form>
  );
}
