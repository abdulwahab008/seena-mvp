'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { setRoomActive } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type RoomRow = {
  id: string;
  code: string;
  name: string;
  room_type: string;
  capacity: number;
  block_label: string | null;
  is_active: boolean;
};

function ToggleActiveButton({ id, isActive }: { id: string; isActive: boolean }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await setRoomActive(id, !isActive, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success(isActive ? 'Room deactivated.' : 'Room activated.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick}>
      {isActive ? 'Deactivate' : 'Activate'}
    </Button>
  );
}

export function RoomList({ rooms }: { rooms: RoomRow[] }) {
  if (rooms.length === 0) {
    return <p className="text-sm text-muted-foreground">No rooms yet.</p>;
  }

  return (
    <div className="space-y-2">
      {rooms.map((r) => (
        <Card key={r.id} data-testid={`room-row-${r.code}`}>
          <CardContent className="flex items-center justify-between p-4">
            <div>
              <p className="font-medium">
                {r.name} <span className="text-muted-foreground">({r.code})</span>
                {r.block_label && <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">{r.block_label}</span>}
                {!r.is_active && <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">inactive</span>}
              </p>
              <p className="text-sm text-muted-foreground">
                {r.room_type.replace(/_/g, ' ')} · capacity {r.capacity}
              </p>
            </div>
            <ToggleActiveButton id={r.id} isActive={r.is_active} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
