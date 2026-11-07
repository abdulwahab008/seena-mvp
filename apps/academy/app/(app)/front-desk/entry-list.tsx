'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { closeEntry } from './actions';
import { KIND_CONFIG, type FrontDeskKind } from './kinds';
import { formatDatePk, formatDateTimePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { EmptyState } from '@/components/ui/empty-state';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

type Entry = {
  id: string;
  person_name: string;
  phone: string | null;
  purpose: string | null;
  host_name: string | null;
  reference: string | null;
  details: string | null;
  opened_at: string;
  follow_up_on: string | null;
  closed_at: string | null;
};

export function EntryList({ kind, entries }: { kind: FrontDeskKind; entries: Entry[] }) {
  const config = KIND_CONFIG[kind];
  const [pending, startTransition] = useTransition();

  if (entries.length === 0) {
    return <EmptyState title={`No ${config.tab.toLowerCase()} in the last 30 days`} description="New entries appear here." />;
  }

  const close = (id: string) =>
    startTransition(async () => {
      const r = await closeEntry(id);
      if (r.error) toast.error(r.error);
    });

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>{config.person}</TableHead>
          <TableHead>Details</TableHead>
          <TableHead>Logged</TableHead>
          <TableHead>Status</TableHead>
          <TableHead className="text-right" />
        </TableRow>
      </TableHeader>
      <TableBody>
        {entries.map((e) => (
          <TableRow key={e.id} data-testid="front-desk-entry">
            <TableCell>
              <div className="font-medium">{e.person_name}</div>
              {e.phone && <div className="text-xs text-muted-foreground">{e.phone}</div>}
            </TableCell>
            <TableCell className="max-w-xs text-sm">
              {[e.purpose, e.host_name && `${config.fields.host_name}: ${e.host_name}`, e.reference, e.details].filter(Boolean).join(' · ')}
              {e.follow_up_on && <div className="text-xs text-muted-foreground">{config.fields.follow_up_on}: {formatDatePk(e.follow_up_on)}</div>}
            </TableCell>
            <TableCell className="text-sm">{formatDateTimePk(e.opened_at)}</TableCell>
            <TableCell>
              {e.closed_at ? (
                <Badge variant="outline">
                  {config.close} {formatDateTimePk(e.closed_at)}
                </Badge>
              ) : (
                <Badge variant="warning" data-testid="entry-open">{config.open}</Badge>
              )}
            </TableCell>
            <TableCell className="text-right">
              {!e.closed_at && (
                <Button size="sm" variant="outline" disabled={pending} onClick={() => close(e.id)}>
                  {config.close}
                </Button>
              )}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
