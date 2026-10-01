'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';

export type SpecField = {
  name: string;
  label: string;
  type?: 'text' | 'number' | 'date' | 'time' | 'datetime-local' | 'textarea' | 'select' | 'checkbox' | 'hidden';
  options?: { value: string; label: string }[];
  required?: boolean;
  placeholder?: string;
  defaultValue?: string;
  step?: string;
  min?: string;
  dir?: 'rtl' | 'ltr';
};

export type SpecResult = { error: string | null; message?: string };

const CONTROL = 'h-9 w-full rounded-md border bg-background px-2 text-sm';

/**
 * A small form driven by a field list. Values reach the server action as
 * strings (checkboxes as 'true' / 'false'); the action validates them with its
 * zod schema and calls the RPC, so every rule lives on the server.
 */
export function SpecForm({
  fields,
  action,
  submitLabel,
  testId,
  resetOnSuccess = true,
  columns = 3,
}: {
  fields: SpecField[];
  action: (values: Record<string, string>) => Promise<SpecResult>;
  submitLabel: string;
  testId: string;
  resetOnSuccess?: boolean;
  columns?: 1 | 2 | 3 | 4;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const grid = { 1: 'sm:grid-cols-1', 2: 'sm:grid-cols-2', 3: 'sm:grid-cols-3', 4: 'sm:grid-cols-4' }[columns];

  const onSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const form = e.currentTarget;
    const values: Record<string, string> = {};
    for (const f of fields) {
      const el = form.elements.namedItem(f.name) as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement | null;
      if (!el) continue;
      values[f.name] = f.type === 'checkbox' ? String((el as HTMLInputElement).checked) : el.value;
    }
    startTransition(async () => {
      const r = await action(values);
      setError(r.error);
      if (!r.error) {
        toast.success(r.message ?? 'Saved.');
        if (resetOnSuccess) setNonce((n) => n + 1);
        router.refresh();
      }
    });
  };

  return (
    <form key={nonce} onSubmit={onSubmit} className="space-y-3" data-testid={testId} noValidate>
      <div className={`grid gap-3 ${grid}`}>
        {fields.map((f) =>
          f.type === 'hidden' ? (
            <input key={f.name} type="hidden" name={f.name} defaultValue={f.defaultValue} />
          ) : (
            <label key={f.name} className={`space-y-1 text-sm ${f.type === 'textarea' ? 'sm:col-span-full' : ''}`}>
              <span className="block text-muted-foreground">
                {f.label}
                {f.required ? ' *' : ''}
              </span>
              {f.type === 'select' ? (
                <select name={f.name} defaultValue={f.defaultValue ?? ''} className={CONTROL} required={f.required}>
                  {!f.required && <option value="">-</option>}
                  {f.required && !f.defaultValue && <option value="">Select</option>}
                  {(f.options ?? []).map((o) => (
                    <option key={o.value} value={o.value}>
                      {o.label}
                    </option>
                  ))}
                </select>
              ) : f.type === 'textarea' ? (
                <textarea name={f.name} defaultValue={f.defaultValue} rows={3} placeholder={f.placeholder} className="w-full rounded-md border bg-background px-3 py-2 text-sm" dir={f.dir} />
              ) : f.type === 'checkbox' ? (
                <input type="checkbox" name={f.name} defaultChecked={f.defaultValue === 'true'} className="block h-4 w-4" />
              ) : (
                <input
                  type={f.type ?? 'text'}
                  name={f.name}
                  defaultValue={f.defaultValue}
                  placeholder={f.placeholder}
                  step={f.step}
                  min={f.min}
                  dir={f.dir}
                  className={CONTROL}
                />
              )}
            </label>
          ),
        )}
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid={`${testId}-error`}>
          {error}
        </p>
      )}
      <Button type="submit" size="sm" disabled={pending} data-testid={`${testId}-submit`}>
        {submitLabel}
      </Button>
    </form>
  );
}

/** A one-click row action (move, close, approve) that reports failures inline. */
export function ActionButton({
  label,
  action,
  variant = 'outline',
  testId,
  confirm,
}: {
  label: string;
  action: () => Promise<SpecResult>;
  variant?: 'outline' | 'default' | 'destructive' | 'ghost';
  testId?: string;
  confirm?: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="inline-flex items-center gap-1">
      <Button
        type="button"
        size="sm"
        variant={variant}
        disabled={pending}
        data-testid={testId}
        onClick={() => {
          if (confirm && !window.confirm(confirm)) return;
          startTransition(async () => {
            const r = await action();
            setError(r.error);
            if (!r.error) {
              if (r.message) toast.success(r.message);
              router.refresh();
            }
          });
        }}
      >
        {label}
      </Button>
      {error && (
        <span role="alert" className="text-xs text-destructive">
          {error}
        </span>
      )}
    </span>
  );
}
