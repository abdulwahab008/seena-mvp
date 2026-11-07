'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { deleteDownload } from './actions';
import { formatDatePk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { EmptyState } from '@/components/ui/empty-state';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

type Item = { id: string; category: string; title: string; fileName: string; sizeBytes: number; createdAt: string; audience: string; canDelete: boolean };

const CATEGORY: Record<string, string> = { syllabus: 'Syllabus', material: 'Study material', other: 'Other' };
const size = (b: number) => (b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1024))} KB`);

export function DownloadList({ items }: { items: Item[] }) {
  const [pending, startTransition] = useTransition();
  if (items.length === 0) return <EmptyState title="Nothing shared yet" description="Files you share appear here and in the parent portal." />;

  const remove = (id: string) =>
    startTransition(async () => {
      const r = await deleteDownload(id);
      if (r.error) toast.error(r.error);
      else toast.success('File removed.');
    });

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Title</TableHead>
          <TableHead>For</TableHead>
          <TableHead>Shared</TableHead>
          <TableHead className="text-right" />
        </TableRow>
      </TableHeader>
      <TableBody>
        {items.map((d) => (
          <TableRow key={d.id} data-testid="download-row">
            <TableCell>
              <a href={`/api/downloads/${d.id}`} className="font-medium text-primary underline">
                {d.title}
              </a>
              <div className="text-xs text-muted-foreground">
                {CATEGORY[d.category] ?? d.category} · {d.fileName} · {size(d.sizeBytes)}
              </div>
            </TableCell>
            <TableCell>{d.audience}</TableCell>
            <TableCell>{formatDatePk(d.createdAt)}</TableCell>
            <TableCell className="text-right">
              {d.canDelete && (
                <Button variant="ghost" size="sm" disabled={pending} onClick={() => remove(d.id)}>
                  Remove
                </Button>
              )}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
