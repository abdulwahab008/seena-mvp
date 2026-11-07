'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { logEntry } from './actions';
import { KIND_CONFIG, type FrontDeskKind } from './kinds';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';

const schema = z.object({
  person_name: z.string().trim().min(1, 'Required').max(200),
  phone: z.string().trim().max(30).optional(),
  purpose: z.string().trim().max(500).optional(),
  host_name: z.string().trim().max(200).optional(),
  reference: z.string().trim().max(100).optional(),
  details: z.string().trim().max(2000).optional(),
  follow_up_on: z.string().optional(),
});
type Values = z.infer<typeof schema>;

export function NewEntryForm({ kind, campusId }: { kind: FrontDeskKind; campusId: string }) {
  const config = KIND_CONFIG[kind];
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, reset, formState: { errors } } = useForm<Values>({ resolver: zodResolver(schema) });

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await logEntry({ ...v, kind, campusId });
      if (r.error) return void toast.error(r.error);
      toast.success('Saved.');
      reset();
    }),
  );

  const field = (name: Exclude<keyof Values, 'person_name'>) => {
    const label = config.fields[name];
    if (!label) return null;
    const id = `fd-${name}`;
    return (
      <div className="space-y-1" key={name}>
        <Label htmlFor={id}>{label}</Label>
        {name === 'details' ? (
          <Textarea id={id} {...register(name)} />
        ) : (
          <Input id={id} type={name === 'follow_up_on' ? 'date' : name === 'phone' ? 'tel' : 'text'} {...register(name)} />
        )}
      </div>
    );
  };

  return (
    <Card className="h-fit">
      <CardHeader>
        <CardTitle>New entry</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="fd-person">{config.person}</Label>
            <Input id="fd-person" {...register('person_name')} />
            {errors.person_name && <p className="text-sm text-destructive">{errors.person_name.message}</p>}
          </div>
          {(['phone', 'purpose', 'host_name', 'reference', 'follow_up_on', 'details'] as const).map(field)}
          <Button type="submit" disabled={pending} className="w-full">
            Save
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
