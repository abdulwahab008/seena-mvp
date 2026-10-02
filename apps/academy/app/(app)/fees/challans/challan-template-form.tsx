'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { setChallanTemplate } from './actions';
import { setChallanTemplateSchema, type SetChallanTemplateInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type ChallanTemplateData = {
  bankName: string;
  bankAccountTitle: string;
  bankAccountNo: string;
  footerNoteEn: string | null;
} | null;

export function ChallanTemplateForm({ campusId, template }: { campusId: string; template: ChallanTemplateData }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<SetChallanTemplateInput>({
    resolver: zodResolver(setChallanTemplateSchema),
    defaultValues: {
      campusId,
      bankName: template?.bankName ?? '',
      bankAccountTitle: template?.bankAccountTitle ?? '',
      bankAccountNo: template?.bankAccountNo ?? '',
      footerNoteEn: template?.footerNoteEn ?? undefined,
    },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('bankName', values.bankName);
    fd.set('bankAccountTitle', values.bankAccountTitle);
    fd.set('bankAccountNo', values.bankAccountNo);
    if (values.footerNoteEn) fd.set('footerNoteEn', values.footerNoteEn);

    startTransition(async () => {
      const result = await setChallanTemplate({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Challan template saved.');
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="bankName">Bank name</Label>
        <Input id="bankName" {...register('bankName')} />
        {errors.bankName && <p className="text-xs text-destructive">{errors.bankName.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="bankAccountTitle">Account title</Label>
        <Input id="bankAccountTitle" {...register('bankAccountTitle')} />
        {errors.bankAccountTitle && <p className="text-xs text-destructive">{errors.bankAccountTitle.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="bankAccountNo">Account number</Label>
        <Input id="bankAccountNo" {...register('bankAccountNo')} />
        {errors.bankAccountNo && <p className="text-xs text-destructive">{errors.bankAccountNo.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="footerNoteEn">Footer note (optional)</Label>
        <Input id="footerNoteEn" {...register('footerNoteEn')} />
      </div>
      <Button type="submit" disabled={pending} data-testid="save-challan-template-button" className="col-span-2 w-fit md:col-span-1">
        {pending ? 'Saving…' : 'Save template'}
      </Button>
    </form>
  );
}
