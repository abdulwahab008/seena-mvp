'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { saveExternalResult } from './actions';
import { externalResultFormSchema, type ExternalResultInput } from './schema';

const FIELDS: { name: keyof ExternalResultInput; label: string; numeric?: boolean }[] = [
  { name: 'grNumber', label: 'GR number' },
  { name: 'board', label: 'Board' },
  { name: 'exam', label: 'Exam' },
  { name: 'examYear', label: 'Year', numeric: true },
  { name: 'rollNo', label: 'Roll number' },
  { name: 'obtained', label: 'Marks obtained', numeric: true },
  { name: 'total', label: 'Total marks', numeric: true },
  { name: 'grade', label: 'Grade' },
];

export function ExternalResultForm({ defaultYear }: { defaultYear: number }) {
  const [pending, startTransition] = useTransition();
  const blank: ExternalResultInput = { grNumber: '', board: '', exam: '', examYear: String(defaultYear), rollNo: '', obtained: '', total: '', grade: '' };
  const { register, handleSubmit, reset, getValues, formState: { errors } } = useForm<ExternalResultInput>({ resolver: zodResolver(externalResultFormSchema), defaultValues: blank });
  const onSubmit = handleSubmit(() =>
    startTransition(async () => {
      const v = getValues();
      const r = await saveExternalResult(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Board result saved.');
      reset({ ...blank, board: v.board, exam: v.exam, examYear: v.examYear, total: v.total });
    }),
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Enter a board result</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-4" noValidate>
          {FIELDS.map((f) => (
            <div key={f.name} className="space-y-1">
              <Label htmlFor={`er-${f.name}`}>{f.label}</Label>
              <Input id={`er-${f.name}`} inputMode={f.numeric ? 'decimal' : undefined} {...register(f.name)} />
              {errors[f.name] && <p className="text-sm text-destructive">{errors[f.name]?.message}</p>}
            </div>
          ))}
          <div className="sm:col-span-4">
            <Button type="submit" disabled={pending}>
              Save result
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}
