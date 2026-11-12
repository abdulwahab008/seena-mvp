'use client';

import Link from 'next/link';
import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { changeStudentFees, decideStudentFees } from './actions';
import { bulkFeePlanOverrideSchema, type BulkFeePlanOverrideInput } from '@/lib/validation';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export type StudentFeeRow = {
  lineId: string;
  studentId: string;
  name: string;
  grNumber: string;
  section: string;
  rollNo: number | null;
  amountPaisa: number;
  pendingAmountPaisa: number | null;
  pending: boolean;
  reason: string | null;
};

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString()}`;

export function StudentFeesDesk({
  rows,
  canApprove,
  canPropose,
  canApproveNow,
}: {
  rows: StudentFeeRow[];
  canApprove: boolean;
  canPropose: boolean;
  canApproveNow: boolean;
}) {
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    setValue,
    reset,
    formState: { errors },
  } = useForm<BulkFeePlanOverrideInput>({
    resolver: zodResolver(bulkFeePlanOverrideSchema),
    defaultValues: { lineIds: [], reason: '', approve: canApproveNow },
  });

  const allSelected = selected.size === rows.length;
  const toggle = (id: string) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const selectedPending = rows.filter((r) => r.pending && selected.has(r.lineId)).map((r) => r.lineId);

  const run = (fn: () => Promise<{ error: string | null; note?: string }>) =>
    startTransition(async () => {
      const result = await fn();
      if (result.error) toast.error(result.error);
      else {
        toast.success(result.note ?? 'Done.');
        setSelected(new Set());
        reset({ lineIds: [], reason: '', approve: canApproveNow });
      }
    });

  const onSubmit = handleSubmit((values) => run(() => changeStudentFees(values)));

  return (
    <div className="space-y-4">
      {canPropose && (
        <form
          onSubmit={(e) => {
            setValue('lineIds', [...selected]);
            void onSubmit(e);
          }}
          className="flex flex-wrap items-end gap-3 rounded-lg border bg-card p-4"
          noValidate
        >
          <div className="space-y-1">
            <Label htmlFor="amountRupees">New amount (PKR)</Label>
            <Input id="amountRupees" type="number" min="0" step="1" className="w-36" placeholder="2500" {...register('amountRupees')} />
            {errors.amountRupees && <p className="text-xs text-destructive">{errors.amountRupees.message}</p>}
          </div>
          <div className="min-w-56 flex-1 space-y-1">
            <Label htmlFor="reason">Reason</Label>
            <Input id="reason" placeholder="e.g. Staff child, hardship, scholarship" {...register('reason')} />
            {errors.reason && <p className="text-xs text-destructive">{errors.reason.message}</p>}
          </div>
          {canApproveNow && (
            <label className="flex h-9 items-center gap-2 text-sm">
              <input type="checkbox" {...register('approve')} />
              Approve now
            </label>
          )}
          <Button type="submit" disabled={pending || selected.size === 0}>
            {pending ? 'Saving…' : `Change fee for ${selected.size} selected`}
          </Button>
          {errors.lineIds && <p className="w-full text-xs text-destructive">{errors.lineIds.message}</p>}
        </form>
      )}

      {canApprove && selectedPending.length > 0 && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-200">
          <span>{selectedPending.length} selected changes are waiting for approval.</span>
          <Button type="button" size="sm" disabled={pending} onClick={() => run(() => decideStudentFees(selectedPending, true))}>
            Approve selected
          </Button>
          <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => run(() => decideStudentFees(selectedPending, false))}>
            Reject selected
          </Button>
        </div>
      )}

      <div className="overflow-x-auto rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-0">
                <input
                  type="checkbox"
                  aria-label="Select all students"
                  checked={allSelected}
                  onChange={() => setSelected(allSelected ? new Set() : new Set(rows.map((r) => r.lineId)))}
                />
              </TableHead>
              <TableHead>Student</TableHead>
              <TableHead>GR no.</TableHead>
              <TableHead>Section · Roll</TableHead>
              <TableHead className="text-right">Current fee</TableHead>
              <TableHead>Change</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.lineId} data-testid={`student-fee-row-${r.grNumber}`}>
                <TableCell>
                  <input type="checkbox" aria-label={`Select ${r.name}`} checked={selected.has(r.lineId)} onChange={() => toggle(r.lineId)} />
                </TableCell>
                <TableCell>
                  <Link href={`/students/${r.studentId}`} className="hover:underline">
                    {r.name}
                  </Link>
                </TableCell>
                <TableCell className="text-muted-foreground">{r.grNumber}</TableCell>
                <TableCell className="text-muted-foreground">
                  {r.section}
                  {r.rollNo != null && ` · ${r.rollNo}`}
                </TableCell>
                <TableCell className="text-right tabular-nums">{pkr(r.amountPaisa)}</TableCell>
                <TableCell>
                  {r.pending && r.pendingAmountPaisa != null && (
                    <Badge variant="warning" title={r.reason ?? undefined}>
                      {pkr(r.pendingAmountPaisa)} awaiting approval
                    </Badge>
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
      <p className="text-xs text-muted-foreground">{rows.length} students</p>
    </div>
  );
}
