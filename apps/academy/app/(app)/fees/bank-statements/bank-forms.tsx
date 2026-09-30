'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { detectHeader } from '@/lib/bank/parse-statement';
import { bankMappingProfileSchema, type BankMappingProfileInput } from '@/lib/validation';
import { saveMappingProfile, uploadBankStatement } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

type Account = { id: string; label: string; hasProfile: boolean };

const selectClass = 'h-10 w-full rounded-md border bg-background px-3 text-sm';

export function UploadForm({ accounts }: { accounts: Account[] }) {
  const [pending, startTransition] = useTransition();
  const [message, setMessage] = useState<{ error: boolean; text: string } | null>(null);

  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    setMessage(null);
    startTransition(async () => {
      const result = await uploadBankStatement(fd);
      if (result.error !== null) setMessage({ error: true, text: result.error });
      else {
        setMessage({ error: false, text: `Imported: ${result.parsed} parsed, ${result.failed} failed of ${result.rows} rows.` });
        toast.success('Statement imported.');
      }
    });
  }

  return (
    <form onSubmit={onSubmit} className="grid gap-4 sm:grid-cols-2">
      <div className="space-y-2">
        <Label htmlFor="bankAccountId">Bank account</Label>
        <select id="bankAccountId" name="bankAccountId" className={selectClass} required>
          {accounts.map((a) => (
            <option key={a.id} value={a.id}>
              {a.label}
              {a.hasProfile ? '' : ' (no profile)'}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="file">Statement (CSV)</Label>
        <Input id="file" name="file" type="file" accept=".csv,text/csv" required />
      </div>
      {message && (
        <p role={message.error ? 'alert' : 'status'} className={`text-sm sm:col-span-2 ${message.error ? 'text-destructive' : 'text-emerald-700'}`} data-testid="upload-message">
          {message.text}
        </p>
      )}
      <div className="sm:col-span-2">
        <Button type="submit" disabled={pending || accounts.length === 0}>
          {pending ? 'Importing…' : 'Import statement'}
        </Button>
      </div>
    </form>
  );
}

export function ProfileForm({ accounts }: { accounts: Account[] }) {
  const [header, setHeader] = useState<string[]>([]);
  const [serverError, setServerError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const form = useForm<BankMappingProfileInput>({
    resolver: zodResolver(bankMappingProfileSchema),
    defaultValues: { bankAccountId: accounts[0]?.id ?? '', name: '', dateFormat: 'DD/MM/YYYY', amountSignRule: 'credit_positive', txnDate: '', challanRef: '', bankRef: '', amount: '', debit: '', credit: '' },
  });
  const rule = form.watch('amountSignRule');

  async function onSample(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0];
    if (f) setHeader(detectHeader(await f.text()));
  }

  const onSubmit = form.handleSubmit((values) => {
    setServerError(null);
    startTransition(async () => {
      const result = await saveMappingProfile(values);
      if (result.error) setServerError(result.error);
      else toast.success('Profile saved and assigned.');
    });
  });

  const col = (name: keyof BankMappingProfileInput, label: string) => (
    <div className="space-y-2">
      <Label htmlFor={name}>{label}</Label>
      <select id={name} className={selectClass} {...form.register(name)}>
        <option value="">—</option>
        {header.map((h) => (
          <option key={h} value={h}>
            {h}
          </option>
        ))}
      </select>
      {form.formState.errors[name] && <p className="text-sm text-destructive">{form.formState.errors[name]?.message}</p>}
    </div>
  );

  return (
    <form onSubmit={onSubmit} className="grid gap-4 sm:grid-cols-2" noValidate>
      <div className="space-y-2 sm:col-span-2">
        <Label htmlFor="sample">Sample file (reads only the header row, nothing is uploaded)</Label>
        <Input id="sample" type="file" accept=".csv,text/csv" onChange={onSample} />
        {header.length > 0 && <p className="text-xs text-muted-foreground">Columns found: {header.join(' · ')}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="profileAccount">Bank account</Label>
        <select id="profileAccount" className={selectClass} {...form.register('bankAccountId')}>
          {accounts.map((a) => (
            <option key={a.id} value={a.id}>
              {a.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="name">Profile name</Label>
        <Input id="name" placeholder="HBL_SCROLL_V2" {...form.register('name')} />
        {form.formState.errors.name && <p className="text-sm text-destructive">{form.formState.errors.name.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="dateFormat">Date format</Label>
        <select id="dateFormat" className={selectClass} {...form.register('dateFormat')}>
          {['DD/MM/YYYY', 'DD-MM-YYYY', 'YYYY-MM-DD', 'DD-Mon-YYYY'].map((f) => (
            <option key={f}>{f}</option>
          ))}
        </select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="amountSignRule">Amounts</Label>
        <select id="amountSignRule" className={selectClass} {...form.register('amountSignRule')}>
          <option value="credit_positive">One column, credits positive</option>
          <option value="absolute">One column, ignore sign</option>
          <option value="separate_columns">Separate debit and credit columns</option>
        </select>
      </div>
      {col('txnDate', 'Date column')}
      {col('challanRef', 'Challan reference column')}
      {col('bankRef', 'Bank reference column')}
      {rule === 'separate_columns' ? (
        <>
          {col('debit', 'Debit column')}
          {col('credit', 'Credit column')}
        </>
      ) : (
        col('amount', 'Amount column')
      )}
      {serverError && (
        <p role="alert" className="text-sm text-destructive sm:col-span-2">
          {serverError}
        </p>
      )}
      <div className="sm:col-span-2">
        <Button type="submit" disabled={pending || header.length === 0}>
          {pending ? 'Saving…' : 'Save and assign profile'}
        </Button>
      </div>
    </form>
  );
}
