'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { addContact, addTask, completeTask } from './actions';
import { CATEGORY_LABEL, contactSchema, taskSchema, type ContactInput, type TaskInput } from './schema';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

export function TaskForm({ staff }: { staff: { id: string; name: string }[] }) {
  const [pending, startTransition] = useTransition();
  const blank: TaskInput = { title: '', assignedTo: '', dueOn: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<TaskInput>({ resolver: zodResolver(taskSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await addTask(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Task added.');
      reset(blank);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-2 sm:grid-cols-[1fr_12rem_10rem_auto] sm:items-end" noValidate>
      <div className="space-y-1">
        <Label htmlFor="tk-title">Task</Label>
        <Input id="tk-title" {...register('title')} />
        {errors.title && <p className="text-sm text-destructive">{errors.title.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="tk-who">For</Label>
        <select id="tk-who" className={SELECT} {...register('assignedTo')}>
          <option value="">Anyone</option>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="tk-due">Due</Label>
        <Input id="tk-due" type="date" {...register('dueOn')} />
      </div>
      <Button type="submit" disabled={pending}>
        Add task
      </Button>
    </form>
  );
}

export function DoneButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="outline"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await completeTask(id);
          if (r.error) toast.error(r.error);
        })
      }
    >
      Done
    </Button>
  );
}

export function ContactForm() {
  const [pending, startTransition] = useTransition();
  const blank: ContactInput = { name: '', organisation: '', category: 'vendor', phone: '', email: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<ContactInput>({ resolver: zodResolver(contactSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await addContact(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Contact added.');
      reset(blank);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-2 sm:grid-cols-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="ct-name">Name</Label>
        <Input id="ct-name" {...register('name')} />
        {errors.name && <p className="text-sm text-destructive">{errors.name.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ct-org">Organisation</Label>
        <Input id="ct-org" {...register('organisation')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="ct-cat">Category</Label>
        <select id="ct-cat" className={SELECT} {...register('category')}>
          {Object.entries(CATEGORY_LABEL).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="ct-phone">Phone</Label>
        <Input id="ct-phone" {...register('phone')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="ct-email">Email</Label>
        <Input id="ct-email" {...register('email')} />
      </div>
      <div className="flex items-end">
        <Button type="submit" disabled={pending}>
          Add contact
        </Button>
      </div>
    </form>
  );
}
