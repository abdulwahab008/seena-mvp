'use client';

import { useTransition } from 'react';
import { useForm, useFieldArray, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { termsSchema, type TermsInput } from '@/lib/validation';
import { saveTerms } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { DatePicker } from '@/components/ui/date-picker';

type ExistingTerm = { name: string; starts_on: string; ends_on: string; weightage: string | number };

export function TermEditor({ sessionId, existingTerms }: { sessionId: string; existingTerms: ExistingTerm[] }) {
  const [pending, startTransition] = useTransition();
  const defaultTerms =
    existingTerms.length > 0
      ? existingTerms.map((t) => ({ name: t.name, startsOn: t.starts_on, endsOn: t.ends_on, weightage: Number(t.weightage) }))
      : [{ name: '', startsOn: '', endsOn: '', weightage: 0 }];

  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<TermsInput>({ resolver: zodResolver(termsSchema), defaultValues: { terms: defaultTerms } });
  const { fields, append, remove } = useFieldArray({ control, name: 'terms' });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('terms', JSON.stringify(values.terms));
    startTransition(async () => {
      const result = await saveTerms(sessionId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Terms saved.');
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-2 rounded-md border p-3" data-testid={`term-editor-${sessionId}`}>
      {fields.map((field, i) => (
        <div key={field.id} className="grid grid-cols-[2fr_1fr_1fr_1fr_auto] items-center gap-2">
          <Input placeholder="Term name" {...register(`terms.${i}.name`)} />
          <Controller
            control={control}
            name={`terms.${i}.startsOn`}
            render={({ field }) => (
              <DatePicker
                id={`term-starts-${i}`}
                name={field.name}
                value={field.value}
                onChange={field.onChange}
                onBlur={field.onBlur}
                placeholder="Starts"
                data-testid={`term-starts-${i}`}
              />
            )}
          />
          <Controller
            control={control}
            name={`terms.${i}.endsOn`}
            render={({ field }) => (
              <DatePicker
                id={`term-ends-${i}`}
                name={field.name}
                value={field.value}
                onChange={field.onChange}
                onBlur={field.onBlur}
                placeholder="Ends"
                data-testid={`term-ends-${i}`}
              />
            )}
          />
          <Input type="number" step="0.01" placeholder="Weight %" {...register(`terms.${i}.weightage`)} />
          <Button type="button" variant="ghost" size="sm" onClick={() => remove(i)} disabled={fields.length <= 1}>
            Remove
          </Button>
        </div>
      ))}
      {errors.terms?.root?.message && <p className="text-sm text-destructive">{errors.terms.root.message}</p>}
      <div className="flex gap-2">
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={fields.length >= 4}
          onClick={() => append({ name: '', startsOn: '', endsOn: '', weightage: 0 })}
        >
          Add term
        </Button>
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? 'Saving…' : 'Save terms'}
        </Button>
      </div>
    </form>
  );
}
