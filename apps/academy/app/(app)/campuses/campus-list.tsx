'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { archiveCampus, restoreCampus, updateCampus } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type CampusRow = {
  id: string;
  code: string;
  name: string;
  city: string | null;
  status: string;
};

function EditCampusForm({ campus, onDone }: { campus: CampusRow; onDone: () => void }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <form
      className="grid w-full grid-cols-1 items-end gap-2 sm:grid-cols-[8rem_1fr_1fr_auto_auto]"
      onSubmit={(e) => {
        e.preventDefault();
        const fd = new FormData(e.currentTarget);
        startTransition(async () => {
          const r = await updateCampus(campus.id, { error: null }, fd);
          if (r.error) setError(r.error);
          else {
            toast.success(`${String(fd.get('name'))} saved.`);
            onDone();
          }
        });
      }}
    >
      <div className="space-y-1">
        <Label htmlFor={`code-${campus.id}`}>Code</Label>
        <Input id={`code-${campus.id}`} name="code" defaultValue={campus.code} />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`name-${campus.id}`}>Name</Label>
        <Input id={`name-${campus.id}`} name="name" defaultValue={campus.name} />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`city-${campus.id}`}>City</Label>
        <Input id={`city-${campus.id}`} name="city" defaultValue={campus.city ?? ''} />
      </div>
      <Button type="submit" size="sm" disabled={pending}>
        Save
      </Button>
      <Button type="button" size="sm" variant="ghost" onClick={onDone}>
        Cancel
      </Button>
      {error && (
        <p role="alert" className="text-sm text-destructive sm:col-span-5">
          {error}
        </p>
      )}
    </form>
  );
}

export function CampusList({ campuses }: { campuses: CampusRow[] }) {
  const [pending, startTransition] = useTransition();
  const [editing, setEditing] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);

  if (campuses.length === 0) {
    return <p className="text-sm text-muted-foreground">No campuses yet.</p>;
  }

  const run = (fn: () => Promise<{ error: string | null }>, ok: string) =>
    startTransition(async () => {
      const r = await fn();
      if (r.error) toast.error(r.error);
      else toast.success(ok);
      setConfirming(null);
    });

  return (
    <div className="space-y-2">
      {campuses.map((c) => (
        <Card key={c.id} data-testid={`campus-card-${c.code}`}>
          <CardContent className="flex flex-wrap items-center justify-between gap-3 p-4">
            {editing === c.id ? (
              <EditCampusForm campus={c} onDone={() => setEditing(null)} />
            ) : (
              <>
                <div>
                  <p className="font-medium">
                    {c.name} <span className="text-muted-foreground">({c.code})</span>
                  </p>
                  <p className="text-sm text-muted-foreground">
                    {c.city ?? 'No city set'} · {c.status === 'active' ? 'Active' : 'Archived'}
                  </p>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  {c.status === 'active' && (
                    <Button variant="outline" size="sm" onClick={() => setEditing(c.id)} data-testid={`campus-edit-${c.code}`}>
                      Edit
                    </Button>
                  )}
                  {c.status === 'active' && confirming !== c.id && (
                    <Button variant="ghost" size="sm" disabled={pending} onClick={() => setConfirming(c.id)}>
                      Archive
                    </Button>
                  )}
                  {confirming === c.id && (
                    <>
                      <span className="text-sm text-muted-foreground">Archive {c.name}? Staff lose access to it.</span>
                      <Button variant="destructive" size="sm" disabled={pending} onClick={() => run(() => archiveCampus(c.id), `${c.name} archived.`)}>
                        Confirm archive
                      </Button>
                      <Button variant="ghost" size="sm" onClick={() => setConfirming(null)}>
                        Keep
                      </Button>
                    </>
                  )}
                  {c.status !== 'active' && (
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={pending}
                      onClick={() => run(() => restoreCampus(c.id), `${c.name} restored. Grant staff access again from the Staff screens.`)}
                    >
                      Restore
                    </Button>
                  )}
                </div>
              </>
            )}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
