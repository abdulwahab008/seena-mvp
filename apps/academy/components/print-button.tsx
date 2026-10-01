'use client';

import { Button } from '@/components/ui/button';

export function PrintButton({ label = 'Print' }: { label?: string }) {
  return (
    <Button type="button" size="sm" onClick={() => window.print()} data-testid="print-button">
      {label}
    </Button>
  );
}
