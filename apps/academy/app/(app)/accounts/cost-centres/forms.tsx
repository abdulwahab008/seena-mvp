'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { saveCostCenter } from '../actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const schema = z.object({
  code: z.string().trim().regex(/^[A-Za-z0-9-]{1,12}$/, 'Up to 12 letters, digits or dashes'),
  name: z.string().trim().min(1, 'Enter a name').max(150),
});

export function CostCenterForm() {
  const [pending, startTransition] = useTransition();
  const blank = { code: '', name: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveCostCenter(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Cost centre added.');
      reset(blank);
    }),
  );
  return (
    <Card className="h-fit">
      <CardHeader>
        <CardTitle className="text-base">Add a cost centre</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="cc-code">Code</Label>
            <Input id="cc-code" placeholder="TRANSPORT" {...register('code')} />
            {errors.code && <p className="text-sm text-destructive">{errors.code.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="cc-name">Name</Label>
            <Input id="cc-name" placeholder="Transport fleet" {...register('name')} />
            {errors.name && <p className="text-sm text-destructive">{errors.name.message}</p>}
          </div>
          <Button type="submit" disabled={pending} className="w-full">
            Add cost centre
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

export function CostCenterActiveButton({ id, code, name, isActive }: { id: string; code: string; name: string; isActive: boolean }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="ghost"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await saveCostCenter({ id, code, name, isActive: !isActive });
          if (r.error) return void toast.error(r.error);
          toast.success(`${name} ${isActive ? 'deactivated' : 'reactivated'}.`);
        })
      }
    >
      {isActive ? 'Deactivate' : 'Reactivate'}
    </Button>
  );
}
