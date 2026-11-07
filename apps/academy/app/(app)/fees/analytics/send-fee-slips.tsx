'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { sendFeeSlips } from './actions';

const schema = z.object({ month: z.string().regex(/^\d{4}-\d{2}$/, 'Choose a month') });

export function SendFeeSlips({ campusId, defaultMonth }: { campusId: string; defaultMonth: string }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: { month: defaultMonth } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await sendFeeSlips(campusId, v.month);
      if (r.error) return void toast.error(r.error);
      toast.success(`Queued ${r.queued} fee ${r.queued === 1 ? 'reminder' : 'reminders'}${r.noPhone ? `; ${r.noPhone} families have no phone` : ''}.`);
    }),
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Send fee slips by WhatsApp now</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
          <p className="w-full text-sm text-muted-foreground">
            One message per unpaid challan for the month, to the parent who receives fee notices. Falls back to SMS where WhatsApp cannot reach. The daily reminder ladder still runs on its own.
          </p>
          <div className="space-y-1">
            <Label htmlFor="slip-month">Billing month</Label>
            <Input id="slip-month" type="month" {...register('month')} />
            {errors.month && <p className="text-sm text-destructive">{errors.month.message}</p>}
          </div>
          <Button type="submit" disabled={pending}>
            Send fee slips
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
