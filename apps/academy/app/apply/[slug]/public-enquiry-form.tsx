'use client';

import { useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { publicEnquirySchema, type PublicEnquiryInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DatePicker } from '@/components/ui/date-picker';

type ClassLevelOption = { code: string; name_en: string; name_ur: string | null };

// AC: the Urdu locale toggles field labels to Urdu and accepts Urdu
// script into the child's name; the confirmation renders right-to-left.
const LABELS = {
  en: {
    locale: 'اردو',
    childName: "Child's name",
    childNameUr: "Child's name (Urdu, optional)",
    dob: 'Date of birth',
    classApplied: 'Class applying for',
    parentName: "Parent/guardian's name",
    phone: 'Phone number',
    whatsapp: 'This number has WhatsApp',
    submit: 'Submit enquiry',
    submitting: 'Submitting…',
    thanks: 'Thank you! Your enquiry number is',
    weWillCall: 'We will contact you on the number you provided.',
  },
  ur: {
    locale: 'English',
    childName: 'بچے کا نام',
    childNameUr: 'بچے کا نام (اردو، اختیاری)',
    dob: 'تاریخ پیدائش',
    classApplied: 'کلاس',
    parentName: 'والدین کا نام',
    phone: 'فون نمبر',
    whatsapp: 'اس نمبر پر واٹس ایپ ہے',
    submit: 'انکوائری جمع کروائیں',
    submitting: 'جمع ہو رہا ہے…',
    thanks: 'شکریہ! آپ کا انکوائری نمبر ہے',
    weWillCall: 'ہم آپ کو فراہم کردہ نمبر پر رابطہ کریں گے۔',
  },
} as const;

export function PublicEnquiryForm({ slug, classLevels }: { slug: string; classLevels: ClassLevelOption[] }) {
  const [pending, startTransition] = useTransition();
  const [locale, setLocale] = useState<'en' | 'ur'>('en');
  const [enquiryNo, setEnquiryNo] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const t = LABELS[locale];

  const {
    register,
    handleSubmit,
    control,
    formState: { errors },
  } = useForm<PublicEnquiryInput>({
    resolver: zodResolver(publicEnquirySchema),
    defaultValues: { classCode: classLevels[0]?.code ?? '', whatsappOptIn: false },
  });

  const onSubmit = handleSubmit((values) => {
    setFormError(null);
    startTransition(async () => {
      const response = await fetch(`/api/public-enquiry/${slug}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(values),
      });
      const body = await response.json();
      if (!response.ok) {
        setFormError(body.error ?? 'Something went wrong.');
        return;
      }
      setEnquiryNo(body.enquiry_no);
    });
  });

  if (enquiryNo) {
    return (
      <div dir={locale === 'ur' ? 'rtl' : 'ltr'} data-testid="enquiry-confirmation">
        <p className="text-lg font-medium">
          {t.thanks} <span data-testid="enquiry-no">{enquiryNo}</span>
        </p>
        <p className="mt-1 text-sm text-muted-foreground">{t.weWillCall}</p>
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="space-y-3" dir={locale === 'ur' ? 'rtl' : 'ltr'} noValidate>
      <button
        type="button"
        className="text-xs text-muted-foreground underline"
        onClick={() => setLocale((l) => (l === 'en' ? 'ur' : 'en'))}
        data-testid="locale-toggle"
      >
        {t.locale}
      </button>

      <div className="space-y-1">
        <Label htmlFor="childName">{t.childName}</Label>
        <Input id="childName" {...register('childName')} />
        {errors.childName && <p className="text-xs text-destructive">{errors.childName.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="childNameUr">{t.childNameUr}</Label>
        <Input id="childNameUr" dir="rtl" {...register('childNameUr')} data-testid="child-name-ur" />
      </div>
      <div className="space-y-1">
        <Label htmlFor="dob">{t.dob}</Label>
        <Controller
          control={control}
          name="dob"
          render={({ field }) => (
            <DatePicker
              id="dob"
              name="dob"
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              placeholder={t.dob}
              data-testid="dob-picker"
            />
          )}
        />
        {errors.dob && <p className="text-xs text-destructive">{errors.dob.message}</p>}
      </div>
      <div className="space-y-1">
        <Label>{t.classApplied}</Label>
        <Controller
          control={control}
          name="classCode"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="public-class-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((c) => (
                  <SelectItem key={c.code} value={c.code}>
                    {locale === 'ur' && c.name_ur ? c.name_ur : c.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="parentName">{t.parentName}</Label>
        <Input id="parentName" {...register('parentName')} />
        {errors.parentName && <p className="text-xs text-destructive">{errors.parentName.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="phone">{t.phone}</Label>
        <Input id="phone" placeholder="03001234567" {...register('phone')} />
        {errors.phone && <p className="text-xs text-destructive">{errors.phone.message}</p>}
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" {...register('whatsappOptIn')} />
        {t.whatsapp}
      </label>

      {formError && (
        <p className="text-sm text-destructive" data-testid="public-enquiry-error">
          {formError}
        </p>
      )}

      <Button type="submit" disabled={pending} className="w-full">
        {pending ? t.submitting : t.submit}
      </Button>
    </form>
  );
}
