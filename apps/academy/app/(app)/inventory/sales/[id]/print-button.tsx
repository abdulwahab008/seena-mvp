'use client';

import { Button } from '@/components/ui/button';

export function PrintButton() {
  return (
    <Button type="button" variant="outline" onClick={() => window.print()} data-testid="print-receipt">
      Print receipt
    </Button>
  );
}
