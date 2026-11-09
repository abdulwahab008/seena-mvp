'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { sendQuickSms } from './actions';
import { QUICK_SMS_MAX, quickSmsSchema, type QuickSmsInput } from './quick-sms-schema';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

export function QuickSmsPanel({ campusId, sections }: { campusId: string; sections: { id: string; label: string }[] }) {
  const [pending, startTransition] = useTransition();
  const blank: QuickSmsInput = { campusId, audience: 'section', sectionId: '', numbers: '', body: '' };
  const { register, handleSubmit, reset, watch, formState: { errors } } = useForm<QuickSmsInput>({ resolver: zodResolver(quickSmsSchema), defaultValues: blank });
  const audience = watch('audience');
  const length = watch('body').length;

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await sendQuickSms(v);
      if (r.error) return void toast.error(r.error);
      if (!r.queued) return void toast.error('No one in that group has a mobile number on file.');
      toast.success(`Queued ${r.queued} SMS${r.skipped ? `; ${r.skipped} had no valid number` : ''}.`);
      reset(blank);
    }),
  );

  return (
    <Card className="h-fit" data-testid="quick-sms">
      <CardHeader>
        <CardTitle>Quick SMS</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="qs-audience">Send to</Label>
            <select id="qs-audience" className={SELECT} {...register('audience')}>
              <option value="section">Parents of a class</option>
              <option value="staff">All staff</option>
              <option value="numbers">Numbers I type</option>
            </select>
          </div>
          {audience === 'section' && (
            <div className="space-y-1">
              <Label htmlFor="qs-section">Class and section</Label>
              <select id="qs-section" className={SELECT} {...register('sectionId')}>
                <option value="">Choose…</option>
                {sections.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.label}
                  </option>
                ))}
              </select>
              {errors.sectionId && <p className="text-sm text-destructive">{errors.sectionId.message}</p>}
            </div>
          )}
          {audience === 'numbers' && (
            <div className="space-y-1">
              <Label htmlFor="qs-numbers">Mobile numbers</Label>
              <Textarea id="qs-numbers" placeholder="0300 1234567, 0321 7654321 (comma or one per line)" {...register('numbers')} />
              {errors.numbers && <p className="text-sm text-destructive">{errors.numbers.message}</p>}
            </div>
          )}
          <div className="space-y-1">
            <Label htmlFor="qs-body">Message</Label>
            <Textarea id="qs-body" rows={4} {...register('body')} />
            <p className={length > QUICK_SMS_MAX ? 'text-xs text-destructive' : 'text-xs text-muted-foreground'}>
              {length}/{QUICK_SMS_MAX} · {Math.max(1, Math.ceil(length / 160))} SMS part{length > 160 ? 's' : ''}
            </p>
            {errors.body && <p className="text-sm text-destructive">{errors.body.message}</p>}
          </div>
          <Button type="submit" disabled={pending} className="w-full">
            Queue SMS
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
