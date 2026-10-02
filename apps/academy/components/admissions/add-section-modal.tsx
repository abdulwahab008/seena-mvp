'use client';

import * as React from 'react';
import { toast } from 'sonner';
import { Plus, Users } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { createSectionAction } from '@/app/(app)/admissions/walk-in/actions';

export interface AddSectionModalProps {
  open: boolean;
  onClose: () => void;
  campusId: string;
  sessionId: string;
  classLevelId: string;
  className: string;
  onSectionCreated: (newSection: { id: string; name: string; class_level_id: string; campus_id: string; session_id: string }) => void;
}

export function AddSectionModal({
  open,
  onClose,
  campusId,
  sessionId,
  classLevelId,
  className,
  onSectionCreated,
}: AddSectionModalProps) {
  const [name, setName] = React.useState('');
  const [capacity, setCapacity] = React.useState('40');
  const [pending, startTransition] = React.useTransition();

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast.error('Please enter a section name (e.g. A, B, Green).');
      return;
    }

    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('classLevelId', classLevelId);
    fd.set('name', name.trim().toUpperCase());
    fd.set('capacity', capacity);

    startTransition(async () => {
      const res = await createSectionAction(fd);
      if (res.error) {
        toast.error(res.error);
      } else if (res.sectionId && res.name) {
        toast.success(`Section ${res.name} created!`);
        onSectionCreated({
          id: res.sectionId,
          name: res.name,
          class_level_id: classLevelId,
          campus_id: campusId,
          session_id: sessionId,
        });
        setName('');
        onClose();
      }
    });
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Add New Section for ${className || 'Class'}`}
      description="Create an additional section to enroll students into this class."
      size="sm"
    >
      <form onSubmit={handleCreate} className="space-y-4 pt-2">
        <div className="space-y-1">
          <Label htmlFor="new-section-name" className="text-xs font-medium">
            Section Name / Identifier <span className="text-destructive">*</span>
          </Label>
          <Input
            id="new-section-name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. B, C, Rose, Blue"
            autoFocus
            required
            className="h-9 font-medium"
          />
        </div>

        <div className="space-y-1">
          <Label htmlFor="new-section-capacity" className="text-xs font-medium">
            Max Student Capacity
          </Label>
          <Input
            id="new-section-capacity"
            type="number"
            value={capacity}
            onChange={(e) => setCapacity(e.target.value)}
            min="1"
            max="200"
            className="h-9"
          />
        </div>

        <div className="flex items-center justify-end gap-2 border-t pt-3">
          <Button type="button" variant="outline" size="sm" onClick={onClose} disabled={pending}>
            Cancel
          </Button>
          <Button type="submit" size="sm" disabled={pending || !name.trim()} className="bg-indigo-600 hover:bg-indigo-700 text-white">
            {pending ? 'Creating…' : 'Create & Select'}
          </Button>
        </div>
      </form>
    </Modal>
  );
}
