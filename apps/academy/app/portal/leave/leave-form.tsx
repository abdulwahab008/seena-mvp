'use client';

import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { leaveApplicationSchema, type LeaveApplicationInput } from '@/lib/validation';
import { t, type Lang, type MessageKey } from '@/lib/i18n/messages';
import { cancelLeave, submitLeave, type LeaveResult } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const CATEGORIES = ['medical', 'family', 'travel', 'religious', 'other'] as const;
const selectClass = 'h-10 w-full rounded-md border bg-background px-3 text-sm';

export function LeaveForm({ lang, students }: { lang: Lang; students: { enrolmentId: string; label: string }[] }) {
  const router = useRouter();
  const fileRef = useRef<HTMLInputElement>(null);
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<LeaveResult | null>(null);
  const form = useForm<LeaveApplicationInput>({
    resolver: zodResolver(leaveApplicationSchema),
    defaultValues: { enrolmentId: students[0]?.enrolmentId ?? '', fromDate: '', toDate: '', category: 'medical', remarks: '' },
  });
  const msg = (key: string | undefined) => (key ? t(lang, key as MessageKey) : null);

  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const fd = new FormData();
      fd.set('enrolmentId', v.enrolmentId);
      fd.set('fromDate', v.fromDate);
      fd.set('toDate', v.toDate);
      fd.set('category', v.category);
      fd.set('remarks', v.remarks ?? '');
      for (const f of Array.from(fileRef.current?.files ?? [])) fd.append('files', f);
      const r = await submitLeave(fd);
      setResult(r);
      if (!r.error) {
        toast.success(t(lang, 'leave.submitted'));
        form.reset({ ...v, fromDate: '', toDate: '', remarks: '' });
        if (fileRef.current) fileRef.current.value = '';
        router.refresh();
      }
    }),
  );

  const errors = form.formState.errors;
  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor="leaveChild">{t(lang, 'leave.child')}</Label>
        <select id="leaveChild" className={selectClass} {...form.register('enrolmentId')}>
          {students.map((c) => (
            <option key={c.enrolmentId} value={c.enrolmentId}>
              {c.label}
            </option>
          ))}
        </select>
        {errors.enrolmentId && <p className="text-sm text-destructive">{msg(errors.enrolmentId.message)}</p>}
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="leaveFrom">{t(lang, 'leave.from')}</Label>
          <Input id="leaveFrom" type="date" {...form.register('fromDate')} />
          {errors.fromDate && <p className="text-sm text-destructive">{msg(errors.fromDate.message)}</p>}
        </div>
        <div className="space-y-2">
          <Label htmlFor="leaveTo">{t(lang, 'leave.to')}</Label>
          <Input id="leaveTo" type="date" {...form.register('toDate')} />
          {errors.toDate && (
            <p className="text-sm text-destructive" data-testid="leave-error-to">
              {msg(errors.toDate.message)}
            </p>
          )}
        </div>
      </div>
      <div className="space-y-2">
        <Label htmlFor="leaveCategory">{t(lang, 'leave.reason')}</Label>
        <select id="leaveCategory" className={selectClass} {...form.register('category')}>
          {CATEGORIES.map((c) => (
            <option key={c} value={c}>
              {t(lang, `leave.cat.${c}` as MessageKey)}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="leaveRemarks">{t(lang, 'leave.remarks')}</Label>
        <textarea id="leaveRemarks" dir="auto" rows={3} className="w-full rounded-md border bg-background px-3 py-2 text-sm" {...form.register('remarks')} />
        {errors.remarks && <p className="text-sm text-destructive">{msg(errors.remarks.message)}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="leaveFiles">{t(lang, 'leave.attachments')}</Label>
        <Input id="leaveFiles" ref={fileRef} type="file" multiple accept="application/pdf,image/jpeg,image/png" />
      </div>
      {result?.error && (
        <p role="alert" className="text-sm text-destructive" data-testid="leave-error">
          {t(lang, result.error.key, result.error.vars)}
        </p>
      )}
      {result && !result.error && result.fileErrors.length > 0 && (
        <ul role="alert" className="space-y-1 text-sm text-destructive" data-testid="leave-file-errors">
          {result.fileErrors.map((f) => (
            <li key={f.name}>
              {f.name}: {t(lang, f.key)}
            </li>
          ))}
        </ul>
      )}
      <Button type="submit" disabled={pending} data-testid="leave-submit">
        {t(lang, 'leave.submit')}
      </Button>
    </form>
  );
}

export function CancelLeaveButton({ lang, leaveId }: { lang: Lang; leaveId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="outline"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          await cancelLeave(leaveId);
          router.refresh();
        })
      }
    >
      {t(lang, 'leave.cancel')}
    </Button>
  );
}
