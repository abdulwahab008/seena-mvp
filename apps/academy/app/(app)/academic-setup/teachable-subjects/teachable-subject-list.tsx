'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { revokeTeachableSubject } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type GrantRow = {
  id: string;
  staff: { full_name: string } | null;
  subject: { code: string; name_en: string } | null;
  class_level_from: { name_en: string } | null;
  class_level_to: { name_en: string } | null;
  stream: { name_en: string } | null;
};

function RevokeButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  const onClick = () => {
    startTransition(async () => {
      const result = await revokeTeachableSubject(id, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Approval revoked.');
    });
  };
  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick} data-testid={`revoke-grant-${id}`}>
      Revoke
    </Button>
  );
}

export function TeachableSubjectList({ grants }: { grants: GrantRow[] }) {
  if (grants.length === 0) {
    return <p className="text-sm text-muted-foreground">No teachable-subject approvals yet.</p>;
  }

  return (
    <div className="space-y-2">
      {grants.map((g) => (
        <Card key={g.id} data-testid={`grant-row-${g.id}`}>
          <CardContent className="flex items-center justify-between p-4">
            <div>
              <p className="font-medium">
                {g.staff?.full_name} — {g.subject?.name_en} ({g.subject?.code})
              </p>
              <p className="text-sm text-muted-foreground">
                {g.class_level_from?.name_en} to {g.class_level_to?.name_en}
                {g.stream ? ` · ${g.stream.name_en} only` : ''}
              </p>
            </div>
            <RevokeButton id={g.id} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
