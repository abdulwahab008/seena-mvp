'use client';

import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

export type FieldDef = {
  name: string;
  label: string;
  type?: 'text' | 'number' | 'date' | 'textarea' | 'select' | 'checkbox' | 'hidden';
  options?: { value: string; label: string }[];
  required?: boolean;
  placeholder?: string;
  step?: string;
  defaultValue?: string;
};

export type ActionValues = Record<string, string>;
export type ActionResult = { error: string | null; message?: string };

const control = 'h-9 w-full rounded-md border bg-background px-2 text-sm';

/**
 * A small form validated on the server. Fields are declared, values go to a
 * server action as strings, and the action parses them with the zod schema
 * for that FR (lib/validation.ts) before calling the RPC.
 */
export function ActionForm({
  fields,
  submitLabel,
  action,
  testId,
  successMessage = 'Saved.',
  resetOnSuccess = true,
}: {
  fields: FieldDef[];
  submitLabel: string;
  action: (values: ActionValues) => Promise<ActionResult>;
  testId: string;
  successMessage?: string;
  resetOnSuccess?: boolean;
}) {
  const router = useRouter();
  const formRef = useRef<HTMLFormElement>(null);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const onSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    const values: ActionValues = {};
    for (const f of fields) {
      values[f.name] = f.type === 'checkbox' ? (fd.get(f.name) ? 'true' : 'false') : String(fd.get(f.name) ?? '');
    }
    startTransition(async () => {
      const r = await action(values);
      setError(r.error);
      if (!r.error) {
        toast.success(r.message ?? successMessage);
        if (resetOnSuccess) formRef.current?.reset();
        router.refresh();
      }
    });
  };

  return (
    <form ref={formRef} onSubmit={onSubmit} className="space-y-3" noValidate data-testid={testId}>
      <div className="grid gap-3 sm:grid-cols-2">
        {fields.map((f) => {
          const id = `${testId}-${f.name}`;
          if (f.type === 'hidden') return <input key={f.name} type="hidden" name={f.name} defaultValue={f.defaultValue} />;
          return (
            <div key={f.name} className={f.type === 'textarea' ? 'space-y-1 sm:col-span-2' : 'space-y-1'}>
              {f.type === 'checkbox' ? (
                <label className="flex items-center gap-2 text-sm" htmlFor={id}>
                  <input id={id} type="checkbox" name={f.name} defaultChecked={f.defaultValue === 'true'} />
                  {f.label}
                </label>
              ) : (
                <>
                  <Label htmlFor={id}>{f.label}</Label>
                  {f.type === 'textarea' ? (
                    <textarea id={id} name={f.name} rows={3} defaultValue={f.defaultValue} placeholder={f.placeholder} className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
                  ) : f.type === 'select' ? (
                    <select id={id} name={f.name} defaultValue={f.defaultValue ?? ''} className={control}>
                      {!f.required && <option value="">None</option>}
                      {f.required && !f.defaultValue && <option value="">Choose</option>}
                      {(f.options ?? []).map((o) => (
                        <option key={o.value} value={o.value}>
                          {o.label}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <input id={id} name={f.name} type={f.type ?? 'text'} step={f.type === 'number' ? (f.step ?? 'any') : undefined} defaultValue={f.defaultValue} placeholder={f.placeholder} className={control} />
                  )}
                </>
              )}
            </div>
          );
        })}
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid={`${testId}-error`}>
          {error}
        </p>
      )}
      <Button type="submit" disabled={pending} data-testid={`${testId}-submit`}>
        {submitLabel}
      </Button>
    </form>
  );
}
