'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { submitApplication } from './actions';
import { ACADEMIC_GROUPS } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type EnquiryRow = {
  id: string;
  enquiry_no: string | null;
  child_name: string;
  phone_e164: string;
  source: string;
  status: string;
};

function SubmitApplicationControl({ enquiryId }: { enquiryId: string }) {
  const [pending, startTransition] = useTransition();
  const [group, setGroup] = useState('');

  const onClick = () => {
    const fd = new FormData();
    fd.set('enquiryId', enquiryId);
    if (group) fd.set('groupApplied', group);
    startTransition(async () => {
      const result = await submitApplication({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Application submitted.');
    });
  };

  return (
    <div className="flex items-center gap-1">
      <Select value={group} onValueChange={setGroup}>
        <SelectTrigger className="h-9 w-40" data-testid={`enquiry-group-trigger-${enquiryId}`}>
          <SelectValue placeholder="Group (9-12 only)" />
        </SelectTrigger>
        <SelectContent>
          {ACADEMIC_GROUPS.map((g) => (
            <SelectItem key={g} value={g}>
              {g.replace(/_/g, ' ')}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Button type="button" size="sm" disabled={pending} onClick={onClick}>
        {pending ? 'Submitting…' : 'Submit application'}
      </Button>
    </div>
  );
}

export function EnquiryList({ enquiries }: { enquiries: EnquiryRow[] }) {
  if (enquiries.length === 0) {
    return <p className="text-sm text-muted-foreground">No enquiries yet.</p>;
  }

  return (
    <div className="space-y-2">
      {enquiries.map((e) => (
        <Card key={e.id} data-testid={`enquiry-row-${e.enquiry_no}`}>
          <CardContent className="flex items-center justify-between p-4">
            <div>
              <p className="font-medium">
                {e.child_name} <span className="text-muted-foreground">({e.enquiry_no})</span>
              </p>
              <p className="text-sm text-muted-foreground">
                {e.phone_e164} · {e.source.replace(/_/g, ' ')} · <span data-testid={`enquiry-status-${e.enquiry_no}`}>{e.status}</span>
              </p>
            </div>
            {e.status === 'open' && <SubmitApplicationControl enquiryId={e.id} />}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
