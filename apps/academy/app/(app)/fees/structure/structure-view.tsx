'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { createDraftStructure, publishStructure } from './actions';
import { StructureLineForm } from './structure-line-form';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

type ClassLevel = { id: string; name_en: string };
type FeeHead = { id: string; code: string; name_en: string };
export type StructureLineRow = {
  id: string;
  className: string;
  groupCode: string | null;
  headName: string;
  amountPaisa: number;
  frequency: string;
};
export type StructureRow = { id: string; status: string; version_no: number } | null;

function CreateDraftButton({ campusId, sessionId }: { campusId: string; sessionId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await createDraftStructure(campusId, sessionId, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Draft structure created.');
    });
  };

  return (
    <Button type="button" disabled={pending} onClick={onClick}>
      {pending ? 'Creating…' : 'Create draft structure'}
    </Button>
  );
}

function PublishButton({ structureId }: { structureId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await publishStructure(structureId, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Structure published.');
    });
  };

  return (
    <Button type="button" disabled={pending} onClick={onClick} data-testid="publish-structure-button">
      {pending ? 'Publishing…' : 'Publish'}
    </Button>
  );
}

export function StructureView({
  campusId,
  sessionId,
  structure,
  lines,
  classLevels,
  feeHeads,
}: {
  campusId: string;
  sessionId: string;
  structure: StructureRow;
  lines: StructureLineRow[];
  classLevels: ClassLevel[];
  feeHeads: FeeHead[];
}) {
  if (!structure) {
    return (
      <div className="space-y-2">
        <p className="text-sm text-muted-foreground">No fee structure exists yet for this campus and session.</p>
        <CreateDraftButton campusId={campusId} sessionId={sessionId} />
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <p className="text-sm">
          Version {structure.version_no} —{' '}
          <span data-testid="structure-status" className="font-medium">
            {structure.status}
          </span>
        </p>
        {structure.status === 'draft' && <PublishButton structureId={structure.id} />}
      </div>

      {structure.status === 'draft' && <StructureLineForm structureId={structure.id} classLevels={classLevels} feeHeads={feeHeads} />}

      <div className="space-y-2">
        {lines.length === 0 ? (
          <p className="text-sm text-muted-foreground">No lines yet.</p>
        ) : (
          lines.map((l) => (
            <Card key={l.id} data-testid={`structure-line-row-${l.className}-${l.headName}-${l.groupCode ?? 'all'}`}>
              <CardContent className="flex items-center justify-between p-3 text-sm">
                <span>
                  {l.className}
                  {l.groupCode ? ` (${l.groupCode})` : ''} · {l.headName}
                </span>
                <span className="text-muted-foreground">
                  PKR {(l.amountPaisa / 100).toLocaleString()} · {l.frequency.replace(/_/g, ' ')}
                </span>
              </CardContent>
            </Card>
          ))
        )}
      </div>
    </div>
  );
}
