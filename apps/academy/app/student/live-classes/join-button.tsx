'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { joinLiveClass } from './actions';

export function JoinButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await joinLiveClass(id);
          if (r.error || !r.url) return void toast.error(r.error ?? 'This class is not available.');
          toast.success('You are marked present.');
          window.open(r.url, '_blank', 'noopener,noreferrer');
        })
      }
    >
      Join
    </Button>
  );
}
