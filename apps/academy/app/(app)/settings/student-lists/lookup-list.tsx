'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { saveLookup, setLookupActive } from './actions';
import { lookupSchema, type LookupInput, type LookupKind } from './schema';

export type LookupEntry = { id: string; name: string; area: string | null; is_active: boolean };

function LookupForm({ kind, entry }: { kind: LookupKind; entry?: LookupEntry }) {
  const [pending, startTransition] = useTransition();
  const withArea = kind === 'school';
  const blank: LookupInput = { kind, id: entry?.id, name: entry?.name ?? '', area: entry?.area ?? '' };
  const { register, handleSubmit, reset, formState: { errors, isDirty } } = useForm<LookupInput>({ resolver: zodResolver(lookupSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveLookup(v);
      if (r.error) return void toast.error(r.error);
      toast.success(entry ? 'Renamed.' : 'Added.');
      reset(entry ? v : blank);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-1 flex-wrap items-start gap-2" noValidate data-testid={entry ? `lookup-edit-${kind}` : `lookup-add-${kind}`}>
      <div className="min-w-40 flex-1 space-y-1">
        <Input aria-label="Name" placeholder={entry ? undefined : 'Name'} className={cn(entry && !entry.is_active && 'text-muted-foreground line-through')} {...register('name')} />
        {errors.name && <p className="text-sm text-destructive">{errors.name.message}</p>}
      </div>
      {withArea && <Input aria-label="Area" placeholder="Area" className="w-40" {...register('area')} />}
      {(!entry || isDirty) && (
        <Button type="submit" size="sm" variant={entry ? 'outline' : 'default'} disabled={pending}>
          {entry ? 'Save' : 'Add'}
        </Button>
      )}
    </form>
  );
}

function ActiveToggle({ entry }: { entry: LookupEntry }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      type="button"
      size="sm"
      variant="ghost"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await setLookupActive(entry.id, !entry.is_active);
          if (r.error) toast.error(r.error);
        })
      }
    >
      {entry.is_active ? 'Deactivate' : 'Reactivate'}
    </Button>
  );
}

export function LookupList({ kind, title, description, entries }: { kind: LookupKind; title: string; description: string; entries: LookupEntry[] }) {
  return (
    <Card data-testid={`lookup-list-${kind}`}>
      <CardHeader>
        <CardTitle className="text-base">{title}</CardTitle>
        <p className="text-sm text-muted-foreground">{description}</p>
      </CardHeader>
      <CardContent className="space-y-3">
        {entries.length === 0 ? (
          <p className="text-sm text-muted-foreground">Nothing on this list yet.</p>
        ) : (
          <ul className="space-y-2">
            {entries.map((e) => (
              <li key={e.id} className="flex items-start gap-2">
                <LookupForm kind={kind} entry={e} />
                <ActiveToggle entry={e} />
              </li>
            ))}
          </ul>
        )}
        <div className="border-t pt-3">
          <LookupForm kind={kind} />
        </div>
      </CardContent>
    </Card>
  );
}
