'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { createDraftStructure, publishStructure, createNextStructureVersion, updateStructureLine, removeStructureLine } from './actions';
import { StructureLineForm, MonthPicker, ALL_MONTHS, frequencyLabel } from './structure-line-form';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { FEE_FREQUENCIES, MONTH_LABELS } from '@/lib/validation';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { DatePicker } from '@/components/ui/date-picker';

type ClassLevel = { id: string; name_en: string };
type FeeHead = { id: string; code: string; name_en: string };
export type StructureLineRow = {
  id: string;
  className: string;
  groupCode: string | null;
  headName: string;
  amountPaisa: number;
  frequency: string;
  billingMonthMask: number;
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
    <div className="flex items-end gap-2">
      <div className="space-y-1">
        <Label htmlFor="effectiveFrom">Revise, effective from</Label>
        <DatePicker id="effectiveFrom" value={effectiveFrom} onChange={setEffectiveFrom} placeholder="Select effective date" />
      </div>
      <Button type="button" disabled={pending} onClick={onClick} data-testid="create-next-version-button">
        {pending ? 'Creating…' : 'Create next version'}
      </Button>
    </div>
  );
}

const maskToMonths = (mask: number) => ALL_MONTHS.filter((m) => mask & (1 << m));

function monthsLabel(mask: number) {
  const months = maskToMonths(mask);
  if (months.length === 12) return 'Every month';
  return months.map((m) => MONTH_LABELS[m]?.slice(0, 3)).join(', ');
}

function LineEditRow({ line, onDone }: { line: StructureLineRow; onDone: () => void }) {
  const [pending, startTransition] = useTransition();
  const [amount, setAmount] = useState(String(line.amountPaisa / 100));
  const [frequency, setFrequency] = useState(line.frequency);
  const [months, setMonths] = useState(maskToMonths(line.billingMonthMask));

  const onSave = () => {
    const fd = new FormData();
    fd.set('lineId', line.id);
    fd.set('amountRupees', amount);
    fd.set('frequency', frequency);
    months.forEach((m) => fd.append('months', String(m)));
    startTransition(async () => {
      const result = await updateStructureLine({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Line updated.');
        onDone();
      }
    });
  };

  return (
    <TableRow className="bg-muted/40 hover:bg-muted/40">
      <TableCell colSpan={5} className="space-y-3 py-3">
        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <Label htmlFor={`amount-${line.id}`}>Amount (PKR)</Label>
            <Input id={`amount-${line.id}`} type="number" min="0" className="h-9 w-32" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label>Frequency</Label>
            <Select value={frequency} onValueChange={setFrequency}>
              <SelectTrigger className="h-9 w-36" aria-label="Frequency">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {FEE_FREQUENCIES.map((f) => (
                  <SelectItem key={f} value={f}>
                    {frequencyLabel(f)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>
        <MonthPicker value={months} onChange={setMonths} />
        <div className="flex gap-2">
          <Button type="button" size="sm" disabled={pending} onClick={onSave}>
            {pending ? 'Saving…' : 'Save'}
          </Button>
          <Button type="button" size="sm" variant="ghost" onClick={onDone}>
            Cancel
          </Button>
        </div>
      </TableCell>
    </TableRow>
  );
}

function LinesTable({ lines, editable }: { lines: StructureLineRow[]; editable: boolean }) {
  const [editingId, setEditingId] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const onDelete = (line: StructureLineRow) => {
    startTransition(async () => {
      const result = await removeStructureLine(line.id);
      if (result.error) toast.error(result.error);
      else toast.success(`Deleted ${line.headName} for ${line.className}.`);
    });
  };

  const byClass = lines.reduce<Map<string, StructureLineRow[]>>((m, l) => m.set(l.className, [...(m.get(l.className) ?? []), l]), new Map());

  return (
    <div className="overflow-x-auto rounded-lg border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Fee head</TableHead>
            <TableHead className="text-right">Amount</TableHead>
            <TableHead>Frequency</TableHead>
            <TableHead>Months</TableHead>
            <TableHead className="w-0" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {[...byClass].map(([className, classLines]) => [
            <TableRow key={className} className="bg-muted/60 hover:bg-muted/60">
              <TableCell colSpan={5} className="py-2 font-medium">
                {className}
                <span className="ml-2 text-xs font-normal text-muted-foreground">
                  PKR {(classLines.filter((l) => l.frequency === 'monthly').reduce((t, l) => t + l.amountPaisa, 0) / 100).toLocaleString()} a month
                </span>
              </TableCell>
            </TableRow>,
            ...classLines.flatMap((l) =>
              editingId === l.id
                ? [<LineEditRow key={l.id} line={l} onDone={() => setEditingId(null)} />]
                : [
                    <TableRow key={l.id} data-testid={`structure-line-row-${l.className}-${l.headName}-${l.groupCode ?? 'all'}`}>
                      <TableCell>
                        {l.headName}
                        {l.groupCode && <span className="ml-1 text-xs text-muted-foreground">({l.groupCode})</span>}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">PKR {(l.amountPaisa / 100).toLocaleString()}</TableCell>
                      <TableCell className="capitalize">{frequencyLabel(l.frequency)}</TableCell>
                      <TableCell className="text-muted-foreground">{monthsLabel(l.billingMonthMask)}</TableCell>
                      <TableCell>
                        {editable && (
                          <div className="flex justify-end gap-1">
                            <Button type="button" size="sm" variant="outline" onClick={() => setEditingId(l.id)}>
                              Edit
                            </Button>
                            <Button
                              type="button"
                              size="sm"
                              variant="ghost"
                              className="text-destructive hover:text-destructive"
                              disabled={pending}
                              aria-label={`Delete ${l.headName} for ${l.className}`}
                              onClick={() => onDelete(l)}
                            >
                              Delete
                            </Button>
                          </div>
                        )}
                      </TableCell>
                    </TableRow>,
                  ]
            ),
          ])}
        </TableBody>
      </Table>
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
  missing = [],
}: {
  campusId: string;
  sessionId: string;
  structure: StructureRow;
  lines: StructureLineRow[];
  history: StructureHistoryRow[];
  classLevels: ClassLevel[];
  feeHeads: FeeHead[];
  missing?: { head: string; classes: string[] }[];
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
      <div className="flex flex-wrap items-end justify-between gap-4 rounded-lg border bg-card p-4">
        <div className="space-y-1">
          <p className="flex items-center gap-2 text-sm font-medium">
            Version {structure.version_no}
            <Badge variant={structure.status === 'draft' ? 'warning' : 'success'} data-testid="structure-status">
              {structure.status}
            </Badge>
          </p>
          <p className="text-xs text-muted-foreground">
            Effective {structure.effective_from}
            {structure.regulator_reference && ` · approved under ${structure.regulator_reference}`}
            {structure.status === 'draft'
              ? ' · lines can be added, edited and deleted until you publish.'
              : ' · published lines are locked; create the next version to change fees.'}
          </p>
        </div>
        {structure.status === 'draft' && <PublishControl structureId={structure.id} />}
        {structure.status === 'published' && <CreateNextVersionControl priorStructureId={structure.id} />}
      </div>

      {structure.status === 'draft' && missing.length > 0 && (
        <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-200" data-testid="structure-missing">
          <p className="font-medium">Before publishing, add these required fee heads:</p>
          <ul className="mt-1 list-disc pl-5">
            {missing.map((m) => (
              <li key={m.head}>
                {m.head}: {m.classes.join(', ')}
              </li>
            ))}
          </ul>
          <p className="mt-1">Use “All classes” in the form below to add a fee head to every class at once.</p>
        </div>
      )}

      {structure.status === 'draft' && <StructureLineForm structureId={structure.id} classLevels={classLevels} feeHeads={feeHeads} />}

      {lines.length === 0 ? (
        <p className="text-sm text-muted-foreground">No fee lines yet. Use the form above to add one.</p>
      ) : (
        <LinesTable lines={lines} editable={structure.status === 'draft'} />
      )}

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
