'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { setRollNo } from './actions';

export function RollInput({ enrolmentId, roll, name }: { enrolmentId: string; roll: number | null; name: string }) {
  const router = useRouter();
  const [value, setValue] = useState(roll == null ? '' : String(roll));
  const [pending, startTransition] = useTransition();
  const save = () => {
    if (value === String(roll ?? '')) return;
    startTransition(async () => {
      const r = await setRollNo(enrolmentId, Number(value));
      if (r.error) {
        toast.error(r.error);
        setValue(roll == null ? '' : String(roll));
      } else {
        toast.success(r.message);
        router.refresh();
      }
    });
  };
  return (
    <>
      <input
        type="number"
        min={1}
        value={value}
        disabled={pending}
        onChange={(e) => setValue(e.target.value)}
        onBlur={save}
        onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()}
        aria-label={`Roll number of ${name}`}
        className="h-8 w-16 rounded-md border bg-background px-2 text-sm tabular print:hidden"
      />
      <span className="hidden print:inline">{roll ?? ''}</span>
    </>
  );
}
