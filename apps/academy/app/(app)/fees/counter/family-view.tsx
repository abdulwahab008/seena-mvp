'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { collectFamilyPayment, lookupFamily, type FamilyChild } from './family-actions';
import { FEE_PAYMENT_MODES } from '@/lib/validation';
import { formatPkr } from '@/lib/challan/html';
import { formatDatePk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

const searchSchema = z.object({ query: z.string().trim().min(1, 'Enter a family number, CNIC, mobile or GR number') });
const paySchema = z.object({
  amountRupees: z.coerce.number().positive('Enter an amount'),
  mode: z.enum(FEE_PAYMENT_MODES),
  referenceNo: z.string().trim().max(100).optional(),
});
type PayValues = z.infer<typeof paySchema>;

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
const MODE_LABEL: Record<string, string> = { cash: 'Cash', bank_challan: 'Bank challan', online: 'Online', cheque: 'Cheque', adjustment: 'Adjustment' };

type Receipt = { receipt_no: string; student_name: string; amount_paisa: number; is_replay: boolean };

export function FamilyCounterView() {
  const [pending, startTransition] = useTransition();
  const [children, setChildren] = useState<FamilyChild[]>([]);
  const [receipts, setReceipts] = useState<Receipt[]>([]);
  const [idemKey, setIdemKey] = useState(() => crypto.randomUUID());
  const search = useForm<z.infer<typeof searchSchema>>({ resolver: zodResolver(searchSchema) });
  const pay = useForm<PayValues>({ resolver: zodResolver(paySchema), defaultValues: { mode: 'cash' } });

  const family = children[0];
  const total = children.reduce((sum, c) => sum + Math.max(c.balance_paisa, 0), 0);

  const onSearch = search.handleSubmit(({ query }) =>
    startTransition(async () => {
      const r = await lookupFamily(query);
      setReceipts([]);
      setChildren(r.children);
      if (r.error) return void toast.error(r.error);
      const due = r.children.reduce((s, c) => s + Math.max(c.balance_paisa, 0), 0);
      pay.reset({ mode: 'cash', amountRupees: due / 100, referenceNo: '' });
      setIdemKey(crypto.randomUUID());
    }),
  );

  const onPay = pay.handleSubmit((v) =>
    startTransition(async () => {
      if (!family) return;
      const r = await collectFamilyPayment({ ...v, familyGroupId: family.family_group_id, clientIdempotencyKey: idemKey });
      if (r.error) return void toast.error(r.error);
      setReceipts(r.receipts);
      toast.success(`Collected for ${r.receipts.length} ${r.receipts.length === 1 ? 'child' : 'children'}.`);
      const refreshed = await lookupFamily(String(family.family_no));
      setChildren(refreshed.children);
      setIdemKey(crypto.randomUUID());
    }),
  );

  return (
    <Card>
      <CardHeader>
        <CardTitle>Family payment</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <form onSubmit={onSearch} className="flex flex-col gap-2 sm:flex-row sm:items-end" noValidate>
          <div className="flex-1 space-y-1">
            <Label htmlFor="family-query">Family no, parent CNIC, mobile or a child&apos;s GR number</Label>
            <Input id="family-query" {...search.register('query')} />
            {search.formState.errors.query && <p className="text-sm text-destructive">{search.formState.errors.query.message}</p>}
          </div>
          <Button type="submit" variant="outline" disabled={pending}>
            Find family
          </Button>
        </form>

        {family && (
          <>
            <p className="text-sm" data-testid="family-heading">
              <span className="font-medium">Family {family.family_no}</span>
              {family.guardian_name ? ` · ${family.guardian_name}` : ''}
              {family.guardian_phone ? ` · ${family.guardian_phone}` : ''}
            </p>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Child</TableHead>
                  <TableHead>GR</TableHead>
                  <TableHead>Class</TableHead>
                  <TableHead>Oldest due</TableHead>
                  <TableHead className="text-right">Owes</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {children.map((c) => (
                  <TableRow key={c.enrolment_id}>
                    <TableCell>{c.student_name}</TableCell>
                    <TableCell>{c.gr_number}</TableCell>
                    <TableCell>{c.class_name}</TableCell>
                    <TableCell>{c.oldest_due_date ? formatDatePk(c.oldest_due_date) : '—'}</TableCell>
                    <TableCell className="text-right">{formatPkr(c.balance_paisa)}</TableCell>
                  </TableRow>
                ))}
                <TableRow>
                  <TableCell colSpan={4} className="font-medium">
                    Family total
                  </TableCell>
                  <TableCell className="text-right font-medium" data-testid="family-total">
                    {formatPkr(total)}
                  </TableCell>
                </TableRow>
              </TableBody>
            </Table>

            {total > 0 && (
              <form onSubmit={onPay} className="grid gap-2 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-end" noValidate>
                <div className="space-y-1">
                  <Label htmlFor="family-amount">Amount (Rs)</Label>
                  <Input id="family-amount" type="number" step="1" {...pay.register('amountRupees')} />
                  {pay.formState.errors.amountRupees && <p className="text-sm text-destructive">{pay.formState.errors.amountRupees.message}</p>}
                </div>
                <div className="space-y-1">
                  <Label htmlFor="family-mode">Paid by</Label>
                  <select id="family-mode" className={SELECT} {...pay.register('mode')}>
                    {FEE_PAYMENT_MODES.map((m) => (
                      <option key={m} value={m}>
                        {MODE_LABEL[m] ?? m}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="space-y-1">
                  <Label htmlFor="family-ref">Reference (optional)</Label>
                  <Input id="family-ref" {...pay.register('referenceNo')} />
                </div>
                <Button type="submit" disabled={pending}>
                  Receive payment
                </Button>
              </form>
            )}
            <p className="text-xs text-muted-foreground">A payment goes to the oldest dues first, across all the children. Each child gets their own receipt.</p>
          </>
        )}

        {receipts.length > 0 && (
          <div className="rounded-md border p-3 text-sm" data-testid="family-receipts">
            <p className="mb-1 font-medium">Receipts</p>
            <ul className="space-y-0.5">
              {receipts.map((r) => (
                <li key={r.receipt_no}>
                  {r.receipt_no} · {r.student_name} · {formatPkr(r.amount_paisa)}
                  {r.is_replay ? ' (already recorded)' : ''}
                </li>
              ))}
            </ul>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
