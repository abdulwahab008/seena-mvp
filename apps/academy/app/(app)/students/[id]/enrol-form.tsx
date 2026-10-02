'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { enrolStudentIntoSection } from '../actions';
import { enrolStudentSchema, type EnrolStudentInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type Section = { id: string; name: string; class_level: { name_en: string } | { name_en: string }[] };

export function EnrolForm({ studentId, sections }: { studentId: string; sections: Section[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const { handleSubmit, control } = useForm<EnrolStudentInput>({ resolver: zodResolver(enrolStudentSchema) });

  const label = (s: Section) => {
    const classLevel = Array.isArray(s.class_level) ? s.class_level[0] : s.class_level;
    return `${classLevel?.name_en ?? ''} · ${s.name}`;
  };

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('sectionId', values.sectionId);

    startTransition(async () => {
      const result = await enrolStudentIntoSection(studentId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Enrolled.');
        router.refresh();
      }
    });
  });

  if (sections.length === 0) {
    return <p className="text-sm text-muted-foreground">No sections available at this campus yet.</p>;
  }

  return (
    <form onSubmit={onSubmit} className="flex items-end gap-2" noValidate>
      <div className="w-64 space-y-1">
        <Controller
          control={control}
          name="sectionId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="enrol-section-trigger">
                <SelectValue placeholder="Select a section" />
              </SelectTrigger>
              <SelectContent>
                {sections.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {label(s)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <Button type="submit" disabled={pending}>
        {pending ? 'Enrolling…' : 'Enrol into section'}
      </Button>
    </form>
  );
}
