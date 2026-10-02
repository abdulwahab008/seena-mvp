'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { seedDefaultLadder, toggleRule } from './actions';

export function SeedButton() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="space-y-2">
      <Button
        type="button"
        disabled={pending}
        data-testid="seed-ladder"
        onClick={() =>
          startTransition(async () => {
            const r = await seedDefaultLadder();
            setError(r.error);
            router.refresh();
          })
        }
      >
        Create the default ladder (day 1 SMS, day 7 WhatsApp, day 15 call)
      </Button>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
    </div>
  );
}

export function RuleToggle({ ruleId, active }: { ruleId: string; active: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <Button
      type="button"
      size="sm"
      variant="outline"
      disabled={pending}
      data-testid="rule-toggle"
      onClick={() =>
        startTransition(async () => {
          await toggleRule(ruleId, !active);
          router.refresh();
        })
      }
    >
      {active ? 'Pause' : 'Resume'}
    </Button>
  );
}
