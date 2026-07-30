'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createEnquiry } from './actions';
import { createEnquirySchema, ENQUIRY_SOURCES, type CreateEnquiryInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type ClassLevel = { id: string; code: string; name_en: string };
type Campus = { id: string; code: string; name: string };
type Session = { id: string; name: string };

export function CreateEnquiryForm({
  campuses,
  sessions,
  classLevels,
}: {
  campuses: Campus[];
  sessions: Session[];
  classLevels: ClassLevel[];
}) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    watch,
    formState: { errors },
  } = useForm<CreateEnquiryInput>({
    resolver: zodResolver(createEnquirySchema),
    defaultValues: {
      campusId: campuses[0]?.id ?? '',
      sessionId: sessions[0]?.id ?? '',
      whatsappOptIn: false,
      source: 'walk_in',
    },
  });
  const source = watch('source');

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('campusId', values.campusId);
    fd.set('sessionId', values.sessionId);
    fd.set('childName', values.childName);
    if (values.childNameUr) fd.set('childNameUr', values.childNameUr);
    fd.set('dob', values.dob);
    fd.set('classAppliedId', values.classAppliedId);
    fd.set('parentName', values.parentName);
    if (values.parentCnic) fd.set('parentCnic', values.parentCnic);
    fd.set('phone', values.phone);
    if (values.whatsappOptIn) fd.set('whatsappOptIn', 'on');
    fd.set('source', values.source);
    if (values.referrerName) fd.set('referrerName', values.referrerName);
    if (values.ageOverrideReason) fd.set('ageOverrideReason', values.ageOverrideReason);

    startTransition(async () => {
      const result = await createEnquiry({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`Enquiry recorded for ${values.childName}.`);
        reset({ campusId: values.campusId, sessionId: values.sessionId, whatsappOptIn: false, source: 'walk_in' });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="campusId">Campus</Label>
        <Controller
          control={control}
          name="campusId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="enquiry-campus-trigger">
                <SelectValue placeholder="Select a campus" />
              </SelectTrigger>
              <SelectContent>
                {campuses.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="sessionId">Session</Label>
        <Controller
          control={control}
          name="sessionId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="enquiry-session-trigger">
                <SelectValue placeholder="Select a session" />
              </SelectTrigger>
              <SelectContent>
                {sessions.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="classAppliedId">Class applied for</Label>
        <Controller
          control={control}
          name="classAppliedId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="enquiry-class-trigger">
                <SelectValue placeholder="Select a class" />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.classAppliedId && <p className="text-xs text-destructive">{errors.classAppliedId.message}</p>}
      </div>

      <div className="space-y-1">
        <Label htmlFor="childName">Child's name</Label>
        <Input id="childName" {...register('childName')} />
        {errors.childName && <p className="text-xs text-destructive">{errors.childName.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="dob">Date of birth</Label>
        <Input id="dob" type="date" {...register('dob')} />
        {errors.dob && <p className="text-xs text-destructive">{errors.dob.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="parentName">Parent/guardian name</Label>
        <Input id="parentName" {...register('parentName')} />
        {errors.parentName && <p className="text-xs text-destructive">{errors.parentName.message}</p>}
      </div>

      <div className="space-y-1">
        <Label htmlFor="phone">Phone</Label>
        <Input id="phone" type="tel" placeholder="03001234567" {...register('phone')} />
        {errors.phone && <p className="text-xs text-destructive">{errors.phone.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="source">Source</Label>
        <Controller
          control={control}
          name="source"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="enquiry-source-trigger">
                <SelectValue placeholder="Select a source" />
              </SelectTrigger>
              <SelectContent>
                {ENQUIRY_SOURCES.map((s) => (
                  <SelectItem key={s} value={s}>
                    {s.replace(/_/g, ' ')}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      {source === 'referral' && (
        <div className="space-y-1">
          <Label htmlFor="referrerName">Referrer name</Label>
          <Input id="referrerName" {...register('referrerName')} />
          {errors.referrerName && <p className="text-xs text-destructive">{errors.referrerName.message}</p>}
        </div>
      )}

      <div className="space-y-1">
        <Label htmlFor="ageOverrideReason">Age override reason (Nursery only, if under 2y6m)</Label>
        <Input id="ageOverrideReason" {...register('ageOverrideReason')} />
      </div>
      <label className="flex items-center gap-2 self-end pb-2 text-sm">
        <input type="checkbox" {...register('whatsappOptIn')} />
        WhatsApp updates opted in
      </label>

      <Button type="submit" disabled={pending} className="col-span-full w-fit">
        {pending ? 'Saving…' : 'Record enquiry'}
      </Button>
    </form>
  );
}
