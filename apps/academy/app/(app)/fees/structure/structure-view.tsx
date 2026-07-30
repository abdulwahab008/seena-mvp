'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { createDraftStructure, publishStructure, createNextStructureVersion, updateStructureLineAmount } from './actions';
import { StructureLineForm } from './structure-line-form';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

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
export type StructureRow = {
  id: string;
  status: string;
  version_no: number;
  effective_from: string;
  regulator_reference: string | null;
} | null;
export type StructureHistoryRow = { id: string; status: string; version_no: number; effective_from: string; regulator_reference: string | null };

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

function PublishControl({ structureId }: { structureId: string }) {
  const [pending, startTransition] = useTransition();
  const [regulatorReference, setRegulatorReference] = useState('');

  const onClick = () => {
    const fd = new FormData();
    if (regulatorReference) fd.set('regulatorReference', regulatorReference);
    startTransition(async () => {
      const result = await publishStructure(structureId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Structure published.');
    });
  };

  return (
    <div className="flex items-end gap-2">
      <div className="space-y-1">
        <Label htmlFor="regulatorReference">Regulator reference (if above the increase cap)</Label>
        <Input
          id="regulatorReference"
          className="w-56"
          placeholder="PEIRA-2027-0042"
          value={regulatorReference}
          onChange={(e) => setRegulatorReference(e.target.value)}
        />
      </div>
      <Button type="button" disabled={pending} onClick={onClick} data-testid="publish-structure-button">
        {pending ? 'Publishing…' : 'Publish'}
      </Button>
    </div>
  );
}

function CreateNextVersionControl({ priorStructureId }: { priorStructureId: string }) {
  const [pending, startTransition] = useTransition();
  const [effectiveFrom, setEffectiveFrom] = useState('');

  const onClick = () => {
    if (!effectiveFrom) {
      toast.error('Choose an effective date.');
      return;
    }
    const fd = new FormData();
    fd.set('priorStructureId', priorStructureId);
    fd.set('effectiveFrom', effectiveFrom);
    startTransition(async () => {
      const result = await createNextStructureVersion({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('New version created.');
    });
  };

  return (
    <div className="flex items-end gap-2 rounded-lg border p-3">
      <div className="space-y-1">
        <Label htmlFor="effectiveFrom">Revise, effective from</Label>
        <Input id="effectiveFrom" type="date" value={effectiveFrom} onChange={(e) => setEffectiveFrom(e.target.value)} />
      </div>
      <Button type="button" disabled={pending} onClick={onClick} data-testid="create-next-version-button">
        {pending ? 'Creating…' : 'Create next version'}
      </Button>
    </div>
  );
}

function LineAmountEditor({ line }: { line: StructureLineRow }) {
  const [pending, startTransition] = useTransition();
  const [editing, setEditing] = useState(false);
  const [amount, setAmount] = useState(String(line.amountPaisa / 100));

  const onSave = () => {
    const fd = new FormData();
    fd.set('lineId', line.id);
    fd.set('amountRupees', amount);
    startTransition(async () => {
      const result = await updateStructureLineAmount({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Amount updated.');
        setEditing(false);
      }
    });
  };

  if (!editing) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setEditing(true)}>
        Edit
      </Button>
    );
  }

  return (
    <div className="flex items-center gap-1">
      <Input type="number" className="h-8 w-24" value={amount} onChange={(e) => setAmount(e.target.value)} />
      <Button type="button" size="sm" disabled={pending} onClick={onSave}>
        Save
      </Button>
    </div>
  );
}

export function StructureView({
  campusId,
  sessionId,
  structure,
  lines,
  history,
  classLevels,
  feeHeads,
}: {
  campusId: string;
  sessionId: string;
  structure: StructureRow;
  lines: StructureLineRow[];
  history: StructureHistoryRow[];
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
          Version {structure.version_no} — <span data-testid="structure-status" className="font-medium">{structure.status}</span> ·
          effective {structure.effective_from}
          {structure.regulator_reference && ` · approved under ${structure.regulator_reference}`}
        </p>
        {structure.status === 'draft' && <PublishControl structureId={structure.id} />}
        {structure.status === 'published' && <CreateNextVersionControl priorStructureId={structure.id} />}
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
                <div className="flex items-center gap-3">
                  <span className="text-muted-foreground">
                    PKR {(l.amountPaisa / 100).toLocaleString()} · {l.frequency.replace(/_/g, ' ')}
                  </span>
                  {structure.status === 'draft' && <LineAmountEditor line={l} />}
                </div>
              </CardContent>
            </Card>
          ))
        )}
      </div>

      {history.length > 0 && (
        <div className="space-y-2">
          <h3 className="text-sm font-medium">Version history</h3>
          {history.map((h) => (
            <p key={h.id} data-testid={`structure-history-${h.version_no}`} className="text-xs text-muted-foreground">
              Version {h.version_no} — {h.status} · effective {h.effective_from}
              {h.regulator_reference && ` · ${h.regulator_reference}`}
            </p>
          ))}
        </div>
      )}
    </div>
  );
}
