'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { saveVaccination } from './actions';
import { Button } from '@/components/ui/button';

export function MarkGivenButton(props: { grNumber: string; vaccine: string; doseNo: number; dueOn: string | null; notes: string | null; today: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="outline"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await saveVaccination({
            grNumber: props.grNumber,
            vaccine: props.vaccine,
            doseNo: String(props.doseNo),
            dueOn: props.dueOn ?? '',
            givenOn: props.today,
            notes: props.notes ?? '',
          });
          if (r.error) toast.error(r.error);
          else toast.success('Marked as given today.');
        })
      }
    >
      Given today
    </Button>
  );
}
