'use client';

import { useState, useTransition } from 'react';
import { useFieldArray, useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { addAccount, backfillLedger, ensureChart, postVoucher, reverseVoucher, setHeadAccount } from './actions';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { Textarea } from '@/components/ui/textarea';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
const money = (v: string) => Number(v || 0);

export function SetupChartButton() {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await ensureChart();
          if (r.error) toast.error(r.error);
        })
      }
    >
      Set up the standard chart of accounts
    </Button>
  );
}

const accountSchema = z.object({ code: z.string().regex(/^\d{3,8}$/, '3 to 8 digits'), name: z.string().trim().min(1, 'Enter a name'), type: z.string() });

export function AccountForm() {
  const [pending, startTransition] = useTransition();
  const blank = { code: '', name: '', type: 'expense' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof accountSchema>>({ resolver: zodResolver(accountSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await addAccount(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Account added.');
      reset(blank);
    }),
  );
  return (
    <Card className="h-fit">
      <CardHeader>
        <CardTitle className="text-base">Add an account</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="acc-code">Code</Label>
            <Input id="acc-code" inputMode="numeric" {...register('code')} />
            {errors.code && <p className="text-sm text-destructive">{errors.code.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="acc-name">Name</Label>
            <Input id="acc-name" {...register('name')} />
            {errors.name && <p className="text-sm text-destructive">{errors.name.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="acc-type">Type</Label>
            <select id="acc-type" className={SELECT} {...register('type')}>
              <option value="asset">Asset</option>
              <option value="liability">Liability</option>
              <option value="equity">Equity</option>
              <option value="income">Income</option>
              <option value="expense">Expense</option>
            </select>
          </div>
          <Button type="submit" disabled={pending} className="w-full">
            Add account
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

const voucherSchema = z.object({
  entryDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  narration: z.string().trim().min(1, 'Enter a narration').max(500),
  lines: z.array(z.object({ accountId: z.string(), debit: z.string(), credit: z.string(), memo: z.string() })),
});
type VoucherValues = z.infer<typeof voucherSchema>;
const blankLine = { accountId: '', debit: '', credit: '', memo: '' };

export function VoucherForm({ accounts }: { accounts: { id: string; label: string }[] }) {
  const [pending, startTransition] = useTransition();
  const blank: VoucherValues = { entryDate: todayPk(), narration: '', lines: [blankLine, blankLine] };
  const { register, control, handleSubmit, watch, reset, formState: { errors } } = useForm<VoucherValues>({ resolver: zodResolver(voucherSchema), defaultValues: blank });
  const { fields, append, remove } = useFieldArray({ control, name: 'lines' });
  const lines = watch('lines');
  const dr = lines.reduce((s, l) => s + money(l.debit), 0);
  const cr = lines.reduce((s, l) => s + money(l.credit), 0);

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await postVoucher({ ...v, lines: v.lines.filter((l) => l.accountId && (money(l.debit) || money(l.credit))) });
      if (r.error) return void toast.error(r.error);
      toast.success('Voucher posted.');
      reset({ ...blank, entryDate: v.entryDate });
    }),
  );

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">New journal voucher</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="grid gap-3 sm:grid-cols-[10rem_1fr]">
            <div className="space-y-1">
              <Label htmlFor="jv-date">Date</Label>
              <Input id="jv-date" type="date" max={todayPk()} {...register('entryDate')} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="jv-narration">Narration</Label>
              <Input id="jv-narration" {...register('narration')} />
              {errors.narration && <p className="text-sm text-destructive">{errors.narration.message}</p>}
            </div>
          </div>
          <div className="space-y-2">
            {fields.map((f, i) => (
              <div key={f.id} className="grid gap-2 sm:grid-cols-[1fr_8rem_8rem_1fr_auto]">
                <select aria-label={`Account, line ${i + 1}`} className={SELECT} {...register(`lines.${i}.accountId`)}>
                  <option value="">Account</option>
                  {accounts.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.label}
                    </option>
                  ))}
                </select>
                <Input aria-label={`Debit, line ${i + 1}`} placeholder="Debit" inputMode="decimal" {...register(`lines.${i}.debit`)} />
                <Input aria-label={`Credit, line ${i + 1}`} placeholder="Credit" inputMode="decimal" {...register(`lines.${i}.credit`)} />
                <Input aria-label={`Memo, line ${i + 1}`} placeholder="Memo" {...register(`lines.${i}.memo`)} />
                <Button type="button" variant="ghost" size="sm" onClick={() => remove(i)} disabled={fields.length <= 2}>
                  Remove
                </Button>
              </div>
            ))}
          </div>
          <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
            <Button type="button" variant="outline" size="sm" onClick={() => append(blankLine)}>
              Add line
            </Button>
            <span className={dr === cr && dr > 0 ? 'text-success' : 'text-destructive'} data-testid="jv-totals">
              Debits {dr.toLocaleString('en-PK')} · Credits {cr.toLocaleString('en-PK')}
              {dr !== cr ? ` · off by ${Math.abs(dr - cr).toLocaleString('en-PK')}` : ''}
            </span>
          </div>
          <Button type="submit" disabled={pending || dr !== cr || dr === 0}>
            Post voucher
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

const reasonSchema = z.object({ reason: z.string().trim().min(1, 'Give a reason').max(300) });

export function ReverseButton({ entryId, entryNo }: { entryId: string; entryNo: string }) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof reasonSchema>>({ resolver: zodResolver(reasonSchema) });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await reverseVoucher(entryId, v.reason);
      if (r.error) return void toast.error(r.error);
      toast.success(`${entryNo} reversed.`);
      setOpen(false);
    }),
  );
  return (
    <>
      <Button size="sm" variant="ghost" onClick={() => setOpen(true)}>
        Reverse
      </Button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={`Reverse ${entryNo}?`}
        description="A new voucher posts the opposite entries. The original stays in the ledger."
        size="sm"
        footer={
          <>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>Cancel</Button>
            <Button type="submit" form={`reverse-${entryId}`} variant="destructive" disabled={pending}>Reverse</Button>
          </>
        }
      >
        <form id={`reverse-${entryId}`} onSubmit={onSubmit} className="space-y-1" noValidate>
          <Label htmlFor={`reason-${entryId}`}>Reason</Label>
          <Textarea id={`reason-${entryId}`} {...register('reason')} />
          {errors.reason && <p className="text-sm text-destructive">{errors.reason.message}</p>}
        </form>
      </Modal>
    </>
  );
}

export function BackfillButton() {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      variant="outline"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await backfillLedger();
          if (r.error) return void toast.error(r.error);
          toast.success(r.posted === 0 ? 'Everything is already posted.' : `Posted ${r.posted} past ${r.posted === 1 ? 'record' : 'records'}.`);
        })
      }
    >
      Post past records
    </Button>
  );
}

export function HeadAccountSelect({
  kind,
  headId,
  headName,
  value,
  accounts,
  fallback,
}: {
  kind: 'fee' | 'expense';
  headId: string;
  headName: string;
  value: string;
  accounts: { code: string; label: string }[];
  fallback: string;
}) {
  const [pending, startTransition] = useTransition();
  return (
    <select
      aria-label={`Account for ${headName}`}
      className={SELECT}
      defaultValue={accounts.some((a) => a.code === value) ? value : ''}
      disabled={pending}
      onChange={(e) => {
        const code = e.target.value;
        startTransition(async () => {
          const r = await setHeadAccount({ kind, headId, code });
          if (r.error) return void toast.error(r.error);
          toast.success(`${headName} saved.`);
        });
      }}
    >
      <option value="">Default ({fallback})</option>
      {accounts.map((a) => (
        <option key={a.code} value={a.code}>
          {a.label}
        </option>
      ))}
    </select>
  );
}
