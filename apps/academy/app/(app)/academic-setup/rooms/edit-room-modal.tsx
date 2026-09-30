'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { Modal } from '@/components/ui/modal';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { ROOM_TYPES, type RoomType } from '@/lib/validation';
import { updateRoom } from './actions';
import { Building, Hash, Users, Layers } from 'lucide-react';

export type RoomItem = {
  id: string;
  code: string;
  name: string;
  room_type: string;
  capacity: number;
  block_label: string | null;
  is_active: boolean;
  assignedSections?: string[];
};

export function EditRoomModal({
  open,
  onClose,
  room,
}: {
  open: boolean;
  onClose: () => void;
  room: RoomItem | null;
}) {
  const [pending, startTransition] = useTransition();

  const [code, setCode] = useState(room?.code || '');
  const [name, setName] = useState(room?.name || '');
  const [roomType, setRoomType] = useState<string>(room?.room_type || 'CLASSROOM');
  const [capacity, setCapacity] = useState<number | ''>(room?.capacity || 30);
  const [blockLabel, setBlockLabel] = useState(room?.block_label || '');

  if (!room) return null;

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();

    if (!code.trim()) {
      toast.error('Room code is required');
      return;
    }
    if (!name.trim()) {
      toast.error('Room name is required');
      return;
    }
    if (!capacity || Number(capacity) < 1) {
      toast.error('Capacity must be at least 1');
      return;
    }

    const finalRoomType = roomType || room.room_type || 'CLASSROOM';

    const fd = new FormData();
    fd.set('code', code.trim());
    fd.set('name', name.trim());
    fd.set('roomType', finalRoomType);
    fd.set('capacity', String(capacity));
    if (blockLabel.trim()) {
      fd.set('blockLabel', blockLabel.trim());
    }

    startTransition(async () => {
      const result = await updateRoom(room.id, { error: null }, fd);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(`Room "${name.trim()}" updated successfully.`);
        onClose();
      }
    });
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Edit Room (${room.code})`}
      description="Update room details, seating capacity, and physical building block."
      size="md"
    >
      <form onSubmit={handleSubmit} className="space-y-4 pt-2">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="edit-code" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <Hash className="h-3.5 w-3.5 text-muted-foreground" />
              Room Code
            </Label>
            <Input
              id="edit-code"
              placeholder="e.g. SL-1, 101"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              className="h-9 font-mono"
              required
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="edit-type" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <Layers className="h-3.5 w-3.5 text-muted-foreground" />
              Room Type
            </Label>
            <Select value={roomType} onValueChange={(val) => val && setRoomType(val)}>
              <SelectTrigger id="edit-type" className="h-9">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {ROOM_TYPES.map((t) => (
                  <SelectItem key={t} value={t}>
                    {t.replace(/_/g, ' ')}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="edit-name" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
            <Building className="h-3.5 w-3.5 text-muted-foreground" />
            Room Name
          </Label>
          <Input
            id="edit-name"
            placeholder="e.g. Science Lab 1, Grade 9 Room"
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="h-9"
            required
          />
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="edit-capacity" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <Users className="h-3.5 w-3.5 text-muted-foreground" />
              Seating Capacity
            </Label>
            <Input
              id="edit-capacity"
              type="number"
              min={1}
              placeholder="30"
              value={capacity}
              onChange={(e) => setCapacity(e.target.value ? parseInt(e.target.value, 10) : '')}
              className="h-9 font-semibold"
              required
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="edit-block" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <Building className="h-3.5 w-3.5 text-muted-foreground" />
              Block / Wing (Optional)
            </Label>
            <Input
              id="edit-block"
              placeholder="e.g. Block C, Science Wing"
              value={blockLabel}
              onChange={(e) => setBlockLabel(e.target.value)}
              className="h-9"
            />
          </div>
        </div>

        {room.assignedSections && room.assignedSections.length > 0 && (
          <div className="rounded-md border border-primary/20 bg-primary/5 p-3">
            <p className="text-xs font-medium text-primary">
              Home Room for: <span className="font-semibold text-foreground">{room.assignedSections.join(', ')}</span>
            </p>
            <p className="text-[11px] text-muted-foreground mt-0.5">
              Sections assigned to this room automatically use it in the timetable.
            </p>
          </div>
        )}

        <div className="flex items-center justify-end gap-2 pt-4 border-t">
          <Button type="button" variant="outline" size="sm" onClick={onClose} disabled={pending}>
            Cancel
          </Button>
          <Button type="submit" size="sm" disabled={pending} className="px-5">
            {pending ? 'Saving Changes…' : 'Save Changes'}
          </Button>
        </div>
      </form>
    </Modal>
  );
}
